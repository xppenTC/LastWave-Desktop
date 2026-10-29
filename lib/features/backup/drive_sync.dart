import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/env/app_env.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/secure_store.dart';
import '../library/playlists.dart';
import '../search/shared_providers.dart';
import 'backup_file.dart';

/// Automatic sync through the backup file kept in the user's own Google
/// Drive, in the hidden app-data folder (`drive.appdata`: this app can see
/// nothing else in the Drive, and nothing else sees the file). The phone
/// app uses the same folder and file name, so both sync without a server.
///
/// Sync runs at launch, 30 s after a playlist change and every 10 minutes.
const driveFileName = 'lastwave-sync.json';

const _scope = 'https://www.googleapis.com/auth/drive.appdata';
const _tokenKey = 'lastwave.drive_refresh_token';

class DriveSyncState {
  final bool available;
  final bool connected;
  final bool syncing;
  final DateTime? lastSync;
  final String? error;
  const DriveSyncState({
    this.available = false,
    this.connected = false,
    this.syncing = false,
    this.lastSync,
    this.error,
  });

  DriveSyncState copyWith({
    bool? connected,
    bool? syncing,
    DateTime? lastSync,
    String? error,
    bool clearError = false,
  }) => DriveSyncState(
    available: available,
    connected: connected ?? this.connected,
    syncing: syncing ?? this.syncing,
    lastSync: lastSync ?? this.lastSync,
    error: clearError ? null : (error ?? this.error),
  );
}

class _StaleFile implements Exception {}

class DriveSyncController extends StateNotifier<DriveSyncState> {
  final Ref _ref;
  final Dio _http = Dio();
  String? _accessToken;
  DateTime _accessExpiry = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _debounce;
  Timer? _periodic;
  ProviderSubscription<List<SavedPlaylist>>? _playlistWatch;
  bool _started = false;

  DriveSyncController(this._ref)
    : super(DriveSyncState(available: AppEnv.googleClientId.isNotEmpty));

  AppDatabase get _db => _ref.read(databaseProvider);
  SecureStore get _store => _ref.read(secureStoreProvider);

  /// Called once at launch: resumes auto-sync when an account is linked.
  Future<void> startup() async {
    if (_started || !state.available) return;
    _started = true;
    final token = await _store.readSecret(_tokenKey);
    if (token == null || token.isEmpty) return;
    state = state.copyWith(connected: true);
    _arm();
    await syncNow();
  }

  /// Browser sign-in (OAuth loopback + PKCE), then a first sync.
  Future<void> connect() async {
    if (!state.available) return;
    final verifier = _randomString(64);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final stateParam = _randomString(24);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}';
    try {
      final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': AppEnv.googleClientId,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': _scope,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': 'consent',
        'state': stateParam,
      });
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw Exception('Could not open the browser');
      }
      final request = await server.first.timeout(const Duration(minutes: 5));
      final params = request.uri.queryParameters;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(
          '<html><body style="font-family:sans-serif">'
          'LastWave: you can close this tab.</body></html>',
        );
      await request.response.close();
      if (params['state'] != stateParam || params['code'] == null) {
        throw Exception(params['error'] ?? 'Google sign-in was cancelled');
      }
      final tokens = await _tokenRequest({
        'grant_type': 'authorization_code',
        'code': params['code']!,
        'redirect_uri': redirect,
        'code_verifier': verifier,
      });
      final refresh = tokens['refresh_token']?.toString();
      if (refresh == null || refresh.isEmpty) {
        throw Exception('Google returned no refresh token');
      }
      await _store.writeSecret(_tokenKey, refresh);
      state = state.copyWith(connected: true, clearError: true);
    } catch (e) {
      state = state.copyWith(error: '$e');
      return;
    } finally {
      await server.close(force: true);
    }
    _arm();
    await syncNow();
  }

  Future<void> disconnect() async {
    _debounce?.cancel();
    _periodic?.cancel();
    _playlistWatch?.close();
    _playlistWatch = null;
    _accessToken = null;
    await _store.writeSecret(_tokenKey, null);
    state = DriveSyncState(available: state.available);
  }

  Future<void> syncNow() async {
    if (!state.connected || state.syncing) return;
    state = state.copyWith(syncing: true, clearError: true);
    try {
      // Another device may write between our read and our write: the
      // version check makes us read and merge again instead of losing it.
      for (var attempt = 0; ; attempt++) {
        try {
          await _syncOnce();
          break;
        } on _StaleFile {
          if (attempt >= 2) rethrow;
        }
      }
      _ref.read(playlistRepositoryProvider.notifier)
        ..refresh()
        ..collapseDuplicateLikedRows();
      state = state.copyWith(syncing: false, lastSync: DateTime.now());
    } catch (e) {
      state = state.copyWith(
        syncing: false,
        error: e is _StaleFile ? 'The file kept changing; try again.' : '$e',
      );
    }
  }

  Future<void> _syncOnce() async {
    final found = await _api(
      'GET',
      'https://www.googleapis.com/drive/v3/files',
      query: {
        'spaces': 'appDataFolder',
        'q': "name = '$driveFileName'",
        'fields': 'files(id,version)',
      },
    );
    final files = (found['files'] as List?) ?? const [];
    if (files.isEmpty) {
      // First device to sync: the file starts as this library.
      await syncBackup(_db, buildBackup(_db), _createFile);
      return;
    }
    final id = files.first['id'] as String;
    final version = '${files.first['version']}';
    final content = await _download(id);
    await syncBackup(_db, content, (merged) async {
      final now = await _api(
        'GET',
        'https://www.googleapis.com/drive/v3/files/$id',
        query: {'fields': 'version'},
      );
      if ('${now['version']}' != version) throw _StaleFile();
      // shortcut: a write landing between this check and the upload is
      // still overwritten; Drive v3 has no conditional upload.
      await _upload(id, merged);
    });
  }

  void _arm() {
    _periodic?.cancel();
    _periodic = Timer.periodic(const Duration(minutes: 10), (_) => syncNow());
    _playlistWatch?.close();
    _playlistWatch = _ref.listen<List<SavedPlaylist>>(
      playlistRepositoryProvider,
      (_, _) {
        if (state.syncing) return; // our own refresh after a sync
        _debounce?.cancel();
        _debounce = Timer(const Duration(seconds: 30), syncNow);
      },
    );
  }

  Future<String> _token() async {
    if (_accessToken != null && DateTime.now().isBefore(_accessExpiry)) {
      return _accessToken!;
    }
    final refresh = await _store.readSecret(_tokenKey);
    if (refresh == null || refresh.isEmpty) {
      throw Exception('Google Drive is not connected');
    }
    final tokens = await _tokenRequest({
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
    });
    _accessToken = tokens['access_token'] as String;
    final seconds = (tokens['expires_in'] as num?)?.toInt() ?? 3600;
    _accessExpiry = DateTime.now().add(Duration(seconds: seconds - 60));
    return _accessToken!;
  }

  Future<Map<String, dynamic>> _tokenRequest(Map<String, String> body) async {
    try {
      final res = await _http.post<Map<String, dynamic>>(
        'https://oauth2.googleapis.com/token',
        data: {
          ...body,
          'client_id': AppEnv.googleClientId,
          'client_secret': AppEnv.googleClientSecret,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return res.data ?? const {};
    } on DioException catch (e) {
      if (e.response?.data is Map &&
          e.response!.data['error'] == 'invalid_grant') {
        // Revoked or expired: ask for a new sign-in.
        await disconnect();
        throw Exception('Google Drive access expired; connect again');
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _api(
    String method,
    String url, {
    Map<String, String>? query,
  }) async {
    final res = await _http.request<Map<String, dynamic>>(
      url,
      queryParameters: query,
      options: Options(
        method: method,
        headers: {'Authorization': 'Bearer ${await _token()}'},
      ),
    );
    return res.data ?? const {};
  }

  Future<String> _download(String id) async {
    final res = await _http.get<String>(
      'https://www.googleapis.com/drive/v3/files/$id',
      queryParameters: {'alt': 'media'},
      options: Options(
        responseType: ResponseType.plain,
        headers: {'Authorization': 'Bearer ${await _token()}'},
      ),
    );
    return res.data ?? '';
  }

  Future<void> _upload(String id, String content) async {
    await _http.patch<void>(
      'https://www.googleapis.com/upload/drive/v3/files/$id',
      queryParameters: {'uploadType': 'media'},
      data: utf8.encode(content),
      options: Options(
        headers: {
          'Authorization': 'Bearer ${await _token()}',
          'Content-Type': 'application/json',
        },
      ),
    );
  }

  Future<void> _createFile(String content) async {
    const boundary = 'lastwave-sync-boundary';
    final body =
        '--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '${jsonEncode({
          'name': driveFileName,
          'parents': ['appDataFolder'],
        })}\r\n'
        '--$boundary\r\n'
        'Content-Type: application/json\r\n\r\n'
        '$content\r\n'
        '--$boundary--';
    await _http.post<void>(
      'https://www.googleapis.com/upload/drive/v3/files',
      queryParameters: {'uploadType': 'multipart'},
      data: utf8.encode(body),
      options: Options(
        headers: {
          'Authorization': 'Bearer ${await _token()}',
          'Content-Type': 'multipart/related; boundary=$boundary',
        },
      ),
    );
  }

  static String _randomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _periodic?.cancel();
    super.dispose();
  }
}

final driveSyncProvider =
    StateNotifierProvider<DriveSyncController, DriveSyncState>(
      (ref) => DriveSyncController(ref),
    );
