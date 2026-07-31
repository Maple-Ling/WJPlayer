import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart' as win32;

import '../app_logger.dart';

typedef MpvIpcDirectoryResolver = Future<Directory> Function();

class MpvIpcBridge {
  MpvIpcBridge._({
    required this.endpoint,
    required this.socketPath,
  });

  static const Duration defaultConnectTimeout = Duration(seconds: 12);
  static const Duration defaultRetryInterval = Duration(milliseconds: 250);
  static const Duration _windowsPollInterval = Duration(milliseconds: 150);
  static const int _readChunkSize = 4096;

  static final AppLogger _logger = AppLogger();

  final String endpoint;
  final String? socketPath;

  final StreamController<Map<String, dynamic>> _messagesController =
      StreamController<Map<String, dynamic>>.broadcast();
  final Queue<String> _pendingWindowsWrites = Queue<String>();

  Socket? _socket;
  StreamSubscription<String>? _socketLinesSubscription;
  Timer? _windowsPollTimer;
  int? _windowsHandle;
  bool _windowsPolling = false;
  bool _closed = false;
  String _pendingText = '';

  Stream<Map<String, dynamic>> get messages => _messagesController.stream;

  static Future<MpvIpcBridge> create({
    required String sessionId,
    MpvIpcDirectoryResolver? directoryResolver,
  }) async {
    final safeSessionId = _sanitizeSessionId(sessionId);
    final endpointName = 'wjplayer-mpv-$safeSessionId';
    if (Platform.isWindows) {
      return MpvIpcBridge._(
        endpoint: '\\\\.\\pipe\\$endpointName',
        socketPath: null,
      );
    }

    final resolver = directoryResolver ?? getTemporaryDirectory;
    final directory = await resolver();
    await directory.create(recursive: true);
    final socketPath = p.join(directory.path, '$endpointName.sock');
    final socketFile = File(socketPath);
    if (await socketFile.exists()) {
      await socketFile.delete();
    }
    return MpvIpcBridge._(
      endpoint: socketPath,
      socketPath: socketPath,
    );
  }

  Future<void> connect({
    Duration timeout = defaultConnectTimeout,
    Duration retryInterval = defaultRetryInterval,
  }) async {
    if (_closed) {
      throw StateError('MPV IPC bridge is already closed.');
    }
    if (Platform.isWindows) {
      await _connectWindows(timeout: timeout, retryInterval: retryInterval);
      return;
    }
    await _connectUnix(timeout: timeout, retryInterval: retryInterval);
  }

  Future<void> sendCommand(
    List<Object?> command, {
    int? requestId,
  }) async {
    final payload = <String, Object?>{'command': command};
    if (requestId != null) {
      payload['request_id'] = requestId;
    }
    final line = jsonEncode(payload);
    if (Platform.isWindows) {
      if (_windowsHandle == null) {
        throw StateError('Windows MPV pipe is not connected.');
      }
      _pendingWindowsWrites.add(line);
      _pollWindowsPipe();
      return;
    }

    final socket = _socket;
    if (socket == null) {
      throw StateError('Unix MPV socket is not connected.');
    }
    socket.write(line);
    socket.write('\n');
    await socket.flush();
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;

    _windowsPollTimer?.cancel();
    _windowsPollTimer = null;

    final linesSubscription = _socketLinesSubscription;
    _socketLinesSubscription = null;
    await linesSubscription?.cancel();

    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close();
      } catch (_) {
        // Ignore socket close failures during cleanup.
      }
    }

    final handle = _windowsHandle;
    _windowsHandle = null;
    if (handle != null) {
      win32.CloseHandle(handle);
    }

    if (!_messagesController.isClosed) {
      await _messagesController.close();
    }

    final path = socketPath;
    if (path != null) {
      final socketFile = File(path);
      if (await socketFile.exists()) {
        await socketFile.delete();
      }
    }
  }

  static Map<String, dynamic>? decodeMessage(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _connectUnix({
    required Duration timeout,
    required Duration retryInterval,
  }) async {
    final deadline = DateTime.now().toUtc().add(timeout);
    while (!_closed) {
      try {
        final socket = await Socket.connect(
          InternetAddress(endpoint, type: InternetAddressType.unix),
          0,
          timeout: retryInterval,
        );
        if (_closed) {
          await socket.close();
          return;
        }
        _socket = socket;
        _socketLinesSubscription = socket
            .cast<List<int>>()
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen(
          _handleIncomingLine,
          onDone: () {
            if (_closed) {
              return;
            }
            if (!_messagesController.isClosed) {
              _messagesController.addError(
                StateError('MPV IPC socket disconnected.'),
              );
            }
            unawaited(close());
          },
          onError: (Object error, StackTrace stackTrace) {
            if (_closed) {
              return;
            }
            if (!_messagesController.isClosed) {
              _messagesController.addError(error, stackTrace);
            }
            unawaited(close());
          },
        );
        return;
      } on SocketException catch (error) {
        if (DateTime.now().toUtc().isAfter(deadline)) {
          throw TimeoutException(
            'Timed out while connecting to MPV IPC socket: ${error.message}',
            timeout,
          );
        }
      }

      await Future.delayed(retryInterval);
    }
  }

  Future<void> _connectWindows({
    required Duration timeout,
    required Duration retryInterval,
  }) async {
    final deadline = DateTime.now().toUtc().add(timeout);
    while (!_closed) {
      final handle = _tryOpenWindowsPipe();
      if (handle != null) {
        _windowsHandle = handle;
        _windowsPollTimer = Timer.periodic(
          _windowsPollInterval,
          (_) => _pollWindowsPipe(),
        );
        _pollWindowsPipe();
        return;
      }

      if (DateTime.now().toUtc().isAfter(deadline)) {
        throw TimeoutException(
          'Timed out while connecting to MPV named pipe: $endpoint',
          timeout,
        );
      }
      await Future.delayed(retryInterval);
    }
  }

  int? _tryOpenWindowsPipe() {
    final endpointPtr = endpoint.toNativeUtf16();
    try {
      final handle = win32.CreateFile(
        endpointPtr,
        win32.GENERIC_READ | win32.GENERIC_WRITE,
        0,
        nullptr,
        win32.OPEN_EXISTING,
        win32.FILE_ATTRIBUTE_NORMAL,
        0,
      );
      if (handle != win32.INVALID_HANDLE_VALUE) {
        final modePtr = calloc<Uint32>();
        try {
          modePtr.value = win32.PIPE_READMODE_BYTE;
          win32.SetNamedPipeHandleState(handle, modePtr, nullptr, nullptr);
        } finally {
          calloc.free(modePtr);
        }
        return handle;
      }

      final errorCode = win32.GetLastError();
      if (errorCode == win32.ERROR_FILE_NOT_FOUND ||
          errorCode == win32.ERROR_PIPE_BUSY) {
        return null;
      }

      throw FileSystemException(
        'Failed to open MPV named pipe (win32=$errorCode)',
        endpoint,
      );
    } finally {
      calloc.free(endpointPtr);
    }
  }

  void _pollWindowsPipe() {
    if (_closed || _windowsPolling) {
      return;
    }
    final handle = _windowsHandle;
    if (handle == null) {
      return;
    }

    _windowsPolling = true;
    try {
      while (_pendingWindowsWrites.isNotEmpty) {
        final nextLine = _pendingWindowsWrites.removeFirst();
        _writeWindowsLine(handle, nextLine);
      }

      while (!_closed) {
        final availableBytes = _peekWindowsAvailableBytes(handle);
        if (availableBytes == null || availableBytes <= 0) {
          break;
        }
        final chunk = _readWindowsBytes(
          handle,
          math.min(availableBytes, _readChunkSize),
        );
        if (chunk.isEmpty) {
          break;
        }
        _ingestIncomingText(utf8.decode(chunk, allowMalformed: true));
      }
    } catch (error, stackTrace) {
      if (!_messagesController.isClosed) {
        _messagesController.addError(error, stackTrace);
      }
      unawaited(close());
    } finally {
      _windowsPolling = false;
    }
  }

  int? _peekWindowsAvailableBytes(int handle) {
    final availablePtr = calloc<Uint32>();
    try {
      final result = win32.PeekNamedPipe(
        handle,
        nullptr,
        0,
        nullptr,
        availablePtr,
        nullptr,
      );
      if (result != 0) {
        return availablePtr.value;
      }

      final errorCode = win32.GetLastError();
      if (errorCode == win32.ERROR_BROKEN_PIPE ||
          errorCode == win32.ERROR_PIPE_NOT_CONNECTED) {
        if (!_messagesController.isClosed) {
          _messagesController.addError(
            StateError('MPV named pipe disconnected (win32=$errorCode).'),
          );
        }
        unawaited(close());
        return null;
      }

      throw FileSystemException(
        'Failed to peek MPV named pipe (win32=$errorCode)',
        endpoint,
      );
    } finally {
      calloc.free(availablePtr);
    }
  }

  List<int> _readWindowsBytes(int handle, int bytesToRead) {
    final bufferPtr = calloc<Uint8>(bytesToRead);
    final readPtr = calloc<Uint32>();
    try {
      final result = win32.ReadFile(
        handle,
        bufferPtr,
        bytesToRead,
        readPtr,
        nullptr,
      );
      if (result == 0) {
        final errorCode = win32.GetLastError();
        if (errorCode == win32.ERROR_BROKEN_PIPE ||
            errorCode == win32.ERROR_PIPE_NOT_CONNECTED) {
          if (!_messagesController.isClosed) {
            _messagesController.addError(
              StateError(
                  'MPV named pipe read disconnected (win32=$errorCode).'),
            );
          }
          unawaited(close());
          return const [];
        }
        throw FileSystemException(
          'Failed to read from MPV named pipe (win32=$errorCode)',
          endpoint,
        );
      }
      return List<int>.from(bufferPtr.asTypedList(readPtr.value));
    } finally {
      calloc.free(bufferPtr);
      calloc.free(readPtr);
    }
  }

  void _writeWindowsLine(int handle, String line) {
    final bytes = utf8.encode('$line\n');
    final bufferPtr = calloc<Uint8>(bytes.length);
    bufferPtr.asTypedList(bytes.length).setAll(0, bytes);
    final writtenPtr = calloc<Uint32>();

    try {
      var offset = 0;
      while (offset < bytes.length) {
        final remaining = bytes.length - offset;
        final result = win32.WriteFile(
          handle,
          bufferPtr + offset,
          remaining,
          writtenPtr,
          nullptr,
        );
        if (result == 0) {
          final errorCode = win32.GetLastError();
          throw FileSystemException(
            'Failed to write to MPV named pipe (win32=$errorCode)',
            endpoint,
          );
        }
        if (writtenPtr.value <= 0) {
          throw StateError('MPV named pipe write returned zero bytes.');
        }
        offset += writtenPtr.value;
      }
    } finally {
      calloc.free(bufferPtr);
      calloc.free(writtenPtr);
    }
  }

  void _ingestIncomingText(String chunk) {
    _pendingText += chunk;
    while (true) {
      final lineBreakIndex = _pendingText.indexOf('\n');
      if (lineBreakIndex < 0) {
        return;
      }
      final rawLine = _pendingText.substring(0, lineBreakIndex);
      _pendingText = _pendingText.substring(lineBreakIndex + 1);
      _handleIncomingLine(rawLine.trimRight());
    }
  }

  void _handleIncomingLine(String line) {
    if (line.isEmpty || _messagesController.isClosed) {
      return;
    }
    final message = decodeMessage(line);
    if (message == null) {
      _logger.w('MpvIpcBridge', 'Ignored malformed MPV IPC line: $line');
      return;
    }
    _messagesController.add(message);
  }

  static String _sanitizeSessionId(String sessionId) {
    final normalized = sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    return normalized.isEmpty ? 'session' : normalized;
  }
}
