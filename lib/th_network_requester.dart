
import 'dart:async';
import 'dart:io';

import 'package:curl_logger_dio_interceptor/curl_logger_dio_interceptor.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:th_logger/th_logger.dart';
import 'package:th_dependencies/th_dependencies.dart' as th_dependencies;

import 'network/network.dart';
import 'common/common.dart';

class THNetworkRequester {
  // static final THNetworkRequester _singleton = THNetworkRequester._internal();
  // factory THNetworkRequester() {
  //   return _singleton;
  // }
  // THNetworkRequester._internal();

  late THRequest? _request;
  late THRequest? _refreshTokenRequest;
  late String _authorizationPrefix;
  late String _refreshTokenPath;
  final Dio _tokenDio = Dio();
  final Dio _dio = Dio();
  final List<THNetworkListener> _listeners = [];
  final th_dependencies.FlutterSecureStorage storage;
  late final th_dependencies.SharedPreferences _prefs;
  late Map<String, dynamic>? _deviceInfo;

  Future<THResponse<Map<String, dynamic>>>? _refreshTokenFuture;

  String languageCode = 'en';

  String? _token;
  String? _refreshToken;
  String? get token => _token;
  String? get baseUrl => _dio.options.baseUrl;
  Map<String, dynamic>? get deviceInfo => _deviceInfo;

  THNetworkRequester(String baseURL, this.storage, {
    int connectTimeout=5000,
    int receiveTimeout=3000,
    required String authorizationPrefix,
    required String refreshTokenPath}) {
    _authorizationPrefix = authorizationPrefix;
    _refreshTokenPath = refreshTokenPath;
    _prefs = th_dependencies.GetIt.I.get<th_dependencies.SharedPreferences>();

    //Initial device info
    _initializationDeviceInfo();

    //Options
    _dio.options.baseUrl = baseURL;
    _dio.options.connectTimeout = connectTimeout;
    _dio.options.receiveTimeout = receiveTimeout;
    _dio.interceptors.add(CurlLoggerDioInterceptor(printOnSuccess: true));

    //Instance to request the token.
    _tokenDio.options.baseUrl = baseURL;
    _tokenDio.options.connectTimeout = connectTimeout;
    _tokenDio.options.receiveTimeout = receiveTimeout;
    _tokenDio.interceptors.add(CurlLoggerDioInterceptor(printOnSuccess: true));

    _tokenDio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        options.headers['Authorization'] = "$_authorizationPrefix $_refreshToken";
        options.headers['Accept-Language'] = languageCode;
        options.headers["Device-Info"] = _deviceInfo;
        return handler.next(options);
      },
      onResponse: (response, handler) {
        THLogger().d("RESPONSE\nstatusCode: ${response.statusCode}\ndata: ${response.data}");

        return handler.next(response);
      },
      onError: (DioError error, handler) {
        THLogger().d("[RefreshToken] DioError\ntype: ${error.type}\nmessage: ${error.message}\n\n"
            "RESPONSE\nstatusCode: ${error.response?.statusCode}\ndata: ${error.response?.data}");

        return handler.next(error);
      }
    ));

    _dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['Authorization'] = "Bearer $_authorizationPrefix $_token";
          options.headers['Accept-Language'] = languageCode;
          options.headers["Device-Info"] = _deviceInfo;
          return handler.next(options);
        },
        onResponse: (response, handler) {
          THLogger().d("RESPONSE\nstatusCode: ${response.statusCode}\ndata: ${response.data}");

          return handler.next(response);
        },
        onError: (DioError error, handler) {
          THLogger().d("DioError\ntype: ${error.type}\nmessage: ${error.message}\n\n"
              "REQUEST\npath: ${error.requestOptions.uri}\n"
              "RESPONSE\nstatusCode: ${error.response?.statusCode}\ndata: ${error.response?.data}");

          return handler.next(error);
        }
    ));

    _request = THRequest(_dio);
    _refreshTokenRequest = THRequest(_tokenDio);
  }

  void _initializationDeviceInfo() async {
    DeviceInfoPlugin deviceInfoPlugin = DeviceInfoPlugin();

    String? deviceModel;
    String? osVersion;
    String? osName;
    String? uuid;
    if (Platform.isIOS) {
      IosDeviceInfo iosDeviceInfo = await deviceInfoPlugin.iosInfo;
      deviceModel = iosDeviceInfo.model;
      osVersion = iosDeviceInfo.systemVersion;
      uuid = iosDeviceInfo.identifierForVendor;// unique ID on iOS
      osName = 'iOS';
    } else if (Platform.isAndroid) {
      AndroidDeviceInfo androidDeviceInfo = await deviceInfoPlugin.androidInfo;
      deviceModel = androidDeviceInfo.model;
      osVersion = '${androidDeviceInfo.version.sdkInt}';
      uuid = androidDeviceInfo.id;// unique ID on Android
      osName = 'Android';
    }

    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    _deviceInfo = <String, dynamic>{
      'device_code': uuid,
      'device_model': deviceModel,
      'os_name': osName,
      'os_version': osVersion,
      'app_version': '${packageInfo.version}+${packageInfo.buildNumber}'
    };
  }

  ///Notify all listeners
  void _notifyListeners() {
    for (var element in _listeners) {
      element.sessionExpired();
    }
  }

  ///Initializes [THNetworkRequester] instance
  Future<void> initialize() async {
    //Check first running application
    if (_prefs.getBool(THNetworkDefines.firstRun) ?? true) {
      await storage.deleteAll();
      _prefs.setBool(THNetworkDefines.firstRun, false);
    }

    //Read token value
    _token = await storage.read(key: THNetworkDefines.tokenKey);
    _refreshToken = await storage.read(key: THNetworkDefines.refreshTokenKey);
  }

  ///Fetch request
  Future<THResponse<T>> _fetch<T>(THRequestMethods method,
      String path, {
        Map<String, dynamic>? queryParameters,
        dynamic data,
        Options? options
      }) async {
    THResponse<T> thResponse = THResponse.somethingWentWrong();
    switch(method) {
      case THRequestMethods.get:
        thResponse = await _request!.get(path, queryParameters: queryParameters, options: options);
        break;
      case THRequestMethods.post:
        thResponse = await _request!.post(path, data: data, queryParameters: queryParameters, options: options);
        break;
      case THRequestMethods.put:
        thResponse = await _request!.put(path, data: data, queryParameters: queryParameters, options: options);
        break;
      case THRequestMethods.delete:
        thResponse = await _request!.delete(path, data: data, queryParameters: queryParameters, options: options);
        break;
      case THRequestMethods.patch:
        thResponse = await _request!.patch(path, data: data, queryParameters: queryParameters, options: options);
        break;
    }

    if (thResponse.code == HttpStatus.unauthorized) {
      _refreshTokenFuture ??= _refreshTokenRequest!.post(_refreshTokenPath);
      THResponse<Map<String, dynamic>> refreshTokenResponse = await _refreshTokenFuture!;

      _refreshTokenFuture = null;
      Map<String, dynamic>? refreshTokenData = refreshTokenResponse.data;
      if (refreshTokenResponse.code == HttpStatus.ok &&
          refreshTokenData != null &&
          refreshTokenData['access_token'] != null &&
          refreshTokenData['refresh_token'] != null) {
        setToken(refreshTokenResponse.data?['access_token'], refreshTokenResponse.data?['refresh_token']);
        return _fetch(method, path, queryParameters: queryParameters, data: data, options: options);
      }
      if (refreshTokenResponse.code == HttpStatus.unauthorized) _notifyListeners();
      return thResponse;
    }
    
    return thResponse;
  }


  ///Set token
  Future<void> setToken(String token, String refreshToken) async {
    _token = token;
    _refreshToken = refreshToken;

    // Write token
    await storage.write(key: THNetworkDefines.tokenKey, value: _token);
    await storage.write(key: THNetworkDefines.refreshTokenKey, value: _refreshToken);
    return;
  }

  ///Delete token
  Future<void> removeToken() async {
    _refreshToken = null;
    _token = null;

    // Write token
    await storage.delete(key: THNetworkDefines.tokenKey);
    await storage.delete(key: THNetworkDefines.refreshTokenKey);
    return;
  }

  void addListener(THNetworkListener listener) => _listeners.add(listener);
  void removeListener(THNetworkListener listener) => _listeners.remove(listener);

  ///Perform network request
  Future<THResponse<T>> executeRequest<T>(
      THRequestMethods method,
      String path, {
        Map<String, dynamic>? queryParameters,
        dynamic data,
        Options? options
      }) async {


    THResponse<T> thResponse = await _fetch(method, path, queryParameters: queryParameters, data: data, options: options);
    return thResponse;
  }
}