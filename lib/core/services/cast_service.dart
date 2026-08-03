import 'dart:async';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

/// DLNA/投屏设备
class CastDevice {
  String id;
  String name;
  String host;
  int port;
  String? location; // 设备描述URL
  String? iconUrl;
  bool isConnected;
  
  CastDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.location,
    this.iconUrl,
    this.isConnected = false,
  });
}

/// 投屏服务（纯HTTP实现，无需mDNS插件）
/// 
/// 通过扫描局域网常见IP段发现DLNA设备
/// 支持手动添加设备
class CastService extends ChangeNotifier {
  final List<CastDevice> _devices = [];
  bool _isScanning = false;
  CastDevice? _connectedDevice;
  
  final Dio _dio = Dio();
  Timer? _scanTimer;
  
  List<CastDevice> get devices => List.unmodifiable(_devices);
  bool get isScanning => _isScanning;
  CastDevice? get connectedDevice => _connectedDevice;
  bool get isConnected => _connectedDevice != null;
  
  /// 开始扫描设备
  Future<void> startDiscovery() async {
    if (_isScanning) return;
    
    _isScanning = true;
    _devices.clear();
    notifyListeners();
    
    try {
      // 扫描常见IP段（路由器常见分配范围）
      await _scanNetworkRange('192.168.1');
      await _scanNetworkRange('192.168.0');
      await _scanNetworkRange('192.168.31'); // 小米路由
      await _scanNetworkRange('10.0.0');
      
      // 扫描特定端口上的DLNA服务
      await _scanDLNAPorts();
      
    } catch (e) {
      debugPrint('设备扫描错误: $e');
    } finally {
      _isScanning = false;
      notifyListeners();
    }
  }
  
  /// 停止扫描
  void stopDiscovery() {
    _scanTimer?.cancel();
    _isScanning = false;
    notifyListeners();
  }
  
  /// 扫描网段
  Future<void> _scanNetworkRange(String subnet) async {
    final ports = [80, 8080, 8008, 8009];
    
    // 扫描1-50号设备（常见分配）
    for (int i = 1; i <= 50; i++) {
      if (!_isScanning) break;
      
      final ip = '$subnet.$i';
      
      for (final port in ports) {
        try {
          final response = await _dio.get(
            'http://$ip:$port',
            options: Options(
              sendTimeout: const Duration(milliseconds: 500),
              receiveTimeout: const Duration(milliseconds: 500),
              validateStatus: (status) => true,
            ),
          );
          
          if (response.statusCode != null) {
            // 尝试获取设备信息
            await _checkDevice(ip, port);
          }
        } catch (_) {
          // 忽略超时和连接错误
        }
      }
      
      // 每扫描10个IP更新一次UI
      if (i % 10 == 0) {
        notifyListeners();
      }
    }
  }
  
  /// 扫描DLNA特定端口
  Future<void> _scanDLNAPorts() async {
    // 常见DLNA端口
    final dlnaPorts = [49152, 49153, 49154, 3900, 32469];
    
    try {
      // 这里简化处理，扫描常见网段
      final subnets = ['192.168.1', '192.168.0', '10.0.0'];
      
      for (final subnet in subnets) {
        for (int i = 1; i <= 30; i++) {
          if (!_isScanning) break;
          
          final ip = '$subnet.$i';
          for (final port in dlnaPorts) {
            try {
              await _dio.get(
                'http://$ip:$port',
                options: Options(
                  sendTimeout: const Duration(milliseconds: 300),
                  receiveTimeout: const Duration(milliseconds: 300),
                  validateStatus: (status) => true,
                ),
              );
              await _checkDevice(ip, port);
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('DLNA扫描错误: $e');
    }
  }
  
  /// 检查设备详情
  Future<void> _checkDevice(String ip, int port) async {
    final paths = [
      '/rootDesc.xml',
      '/description.xml',
      '/DeviceDescription.xml',
      '/dmr',
      '/upnp/dev/1/dd.xml',
    ];
    
    for (final path in paths) {
      try {
        final response = await _dio.get(
          'http://$ip:$port$path',
          options: Options(
            sendTimeout: const Duration(seconds: 1),
            receiveTimeout: const Duration(seconds: 1),
          ),
        );
        
        if (response.statusCode == 200 && response.data.toString().contains('<deviceType>')) {
          final xmlDoc = XmlDocument.parse(response.data);
          
          final deviceType = xmlDoc.findAllElements('deviceType').firstOrNull?.value ?? '';
          
          // 只处理媒体渲染设备
          if (deviceType.contains('MediaRenderer') || 
              deviceType.contains('MediaServer')) {
            final friendlyName = xmlDoc.findAllElements('friendlyName').firstOrNull?.value ?? '未知设备';
            final manufacturer = xmlDoc.findAllElements('manufacturer').firstOrNull?.value ?? '';
            
            final device = CastDevice(
              id: '${ip}_$port',
              name: friendlyName.isNotEmpty ? friendlyName : manufacturer,
              host: ip,
              port: port,
              location: 'http://$ip:$port$path',
            );
            
            // 提取图标
            final iconUrl = xmlDoc.findAllElements('icon').firstOrNull?.findElements('url').firstOrNull?.value;
            if (iconUrl != null) {
              device.iconUrl = iconUrl.startsWith('http') 
                  ? iconUrl 
                  : 'http://$ip:$port$iconUrl';
            }
            
            if (!_devices.any((d) => d.id == device.id)) {
              _devices.add(device);
              notifyListeners();
            }
          }
          
          break; // 找到有效路径后停止
        }
      } catch (_) {}
    }
  }
  
  /// 手动添加设备
  void addDeviceManually(String name, String host, int port) {
    final device = CastDevice(
      id: '${host}_$port',
      name: name,
      host: host,
      port: port,
    );
    
    if (!_devices.any((d) => d.id == device.id)) {
      _devices.add(device);
      notifyListeners();
    }
  }
  
  /// 连接设备
  Future<bool> connect(CastDevice device) async {
    try {
      await _dio.get(
        'http://${device.host}:${device.port}',
        options: Options(
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
      
      _connectedDevice = device;
      device.isConnected = true;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('连接设备失败: $e');
      return false;
    }
  }
  
  /// 断开连接
  Future<void> disconnect() async {
    if (_connectedDevice != null) {
      _connectedDevice!.isConnected = false;
      _connectedDevice = null;
      notifyListeners();
    }
  }
  
  /// 投屏播放
  Future<bool> castVideo(String videoUrl, {String? title}) async {
    if (_connectedDevice == null) return false;
    
    try {
      // DLNA SetAVTransportURI 动作
      final soapBody = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <CurrentURI>$videoUrl</CurrentURI>
      <CurrentURIMetaData></CurrentURIMetaData>
    </u:SetAVTransportURI>
  </s:Body>
</s:Envelope>''';      
      await _dio.post(
        'http://${_connectedDevice!.host}:${_connectedDevice!.port}/MediaRenderer/AVTransport/Control',
        data: soapBody,
        options: Options(
          headers: {
            'Content-Type': 'text/xml; charset="utf-8"',
            'SOAPAction': '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"',
          },
        ),
      );
      
      // 发送播放命令
      const playBody = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Speed>1</Speed>
    </u:Play>
  </s:Body>
</s:Envelope>''';
      
      await _dio.post(
        'http://${_connectedDevice!.host}:${_connectedDevice!.port}/MediaRenderer/AVTransport/Control',
        data: playBody,
        options: Options(
          headers: {
            'Content-Type': 'text/xml; charset="utf-8"',
            'SOAPAction': '"urn:schemas-upnp-org:service:AVTransport:1#Play"',
          },
        ),
      );
      
      return true;
    } catch (e) {
      debugPrint('投屏失败: $e');
      return false;
    }
  }
  
  @override
  void dispose() {
    stopDiscovery();
    super.dispose();
  }
}
