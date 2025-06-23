import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:convert';
import 'dart:async';

class WebSocketService {
  final String _wsUrl;
  WebSocketChannel? _channel;
  StreamController<Map<String, dynamic>>? _storageLogController;
  bool _isConnected = false;
  Timer? _reconnectTimer;

  WebSocketService(this._wsUrl) {
    _connect();
  }

  Stream<Map<String, dynamic>> get storageLogStream {
    _storageLogController ??= StreamController<Map<String, dynamic>>.broadcast();
    return _storageLogController!.stream;
  }

  Future<void> _connect() async {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      _isConnected = true;
      print('WebSocket connected to $_wsUrl');

      _channel!.stream.listen(
            (message) {
          try {
            final data = jsonDecode(message) as Map<String, dynamic>;
            if (data['type'] == 'storage_log_update' && _storageLogController != null) {
              _storageLogController!.add(data['data']);
            }
          } catch (e) {
            print('Error parsing WebSocket message: $e');
          }
        },
        onError: (error) {
          print('WebSocket error: $error');
          _handleDisconnect();
        },
        onDone: () {
          print('WebSocket closed');
          _handleDisconnect();
        },
      );
    } catch (e) {
      print('WebSocket connection error: $e');
      _handleDisconnect();
    }
  }

  void _handleDisconnect() {
    _isConnected = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!_isConnected) {
        print('Attempting to reconnect WebSocket...');
        _connect();
      } else {
        timer.cancel();
      }
    });
  }

  Future<void> subscribeToStorageLogs(String userId) async {
    if (!_isConnected || _channel == null) {
      await _connect();
    }
    try {
      _channel!.sink.add(jsonEncode({
        'type': 'subscribe',
        'userId': userId,
      }));
      print('Subscribed to storage logs for user: $userId');
    } catch (e) {
      print('Error subscribing to storage logs: $e');
      rethrow;
    }
  }

  Future<void> subscribeToStorageLog(String logId) async {
    if (!_isConnected || _channel == null) {
      await _connect();
    }
    try {
      _channel!.sink.add(jsonEncode({
        'type': 'subscribe_log',
        'logId': logId,
      }));
      print('Subscribed to storage log: $logId');
    } catch (e) {
      print('Error subscribing to storage log: $e');
      rethrow;
    }
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _storageLogController?.close();
    _channel?.sink.close();
    _isConnected = false;
    print('WebSocketService disposed');
  }
}