
import 'dart:async';

import 'package:curl_logger_dio_interceptor/curl_logger_dio_interceptor.dart';
import 'package:dio/dio.dart';
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

  Future<THResponse<Map<String, dynamic>>>? _refreshTokenFuture;

  String languageCode = 'en';

  String? _token;
  String? _refreshToken;
  String? get token => _token;

  THNetworkRequester(String baseURL, this.storage, {
    int connectTimeout=5000,
    int receiveTimeout=3000,
    required String authorizationPrefix,
    required String refreshTokenPath}) {
    _authorizationPrefix = authorizationPrefix;
    _refreshTokenPath = refreshTokenPath;
    _prefs = th_dependencies.GetIt.I.get<th_dependencies.SharedPreferences>();

    //Options
    _dio.options.baseUrl = baseURL;
    _dio.options.connectTimeout = connectTimeout;
    _dio.options.receiveTimeout = receiveTimeout;
    _dio.interceptors.add(CurlLoggerDioInterceptor());

    //Instance to request the token.
    _tokenDio.options.baseUrl = baseURL;
    _tokenDio.options.connectTimeout = connectTimeout;
    _tokenDio.options.receiveTimeout = receiveTimeout;

    _tokenDio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        options.headers['Authorization'] = "$_authorizationPrefix $_refreshToken";
        options.headers['Accept-Language'] = languageCode;
        return handler.next(options);
      },
      onResponse: (response, handler) {
        THLogger().d("[RefreshToken] REQUEST\nmethod: ${response.requestOptions.method}\n"
            "path: ${response.requestOptions.path}\nheaders:${response.requestOptions.headers}\n"
            "queryParameters: ${response.requestOptions.queryParameters}\ndata: ${response.requestOptions.data}\n\n\n"
            "RESPONSE\nstatusCode: ${response.statusCode}\ndata: ${response.data}");

        return handler.next(response);
      },
      onError: (DioError error, handler) {
        THLogger().d("[RefreshToken] DioError\ntype: ${error.type}\nmessage: ${error.message}\n\n"
            "REQUEST\npath: ${error.requestOptions.path}\nheaders:${error.requestOptions.headers}"
            "queryParameters: ${error.requestOptions.queryParameters}\ndata: ${error.requestOptions.data}\n\n "
            "RESPONSE\nstatusCode: ${error.response?.statusCode}\ndata: ${error.response?.data}");

        return handler.next(error);
      }
    ));

    _dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['Authorization'] = "$_authorizationPrefix $_token";
          options.headers['Accept-Language'] = languageCode;
          return handler.next(options);
        },
        onResponse: (response, handler) {
          THLogger().d("REQUEST\nmethod: ${response.requestOptions.method}\n"
              "path: ${response.requestOptions.path}\nheaders:${response.requestOptions.headers}\n"
              "queryParameters: ${response.requestOptions.queryParameters}\ndata: ${response.requestOptions.data}\n\n\n"
              "RESPONSE\nstatusCode: ${response.statusCode}\ndata: ${response.data}");

          return handler.next(response);
        },
        onError: (DioError error, handler) {
          THLogger().d("DioError\ntype: ${error.type}\nmessage: ${error.message}\n\n"
              "REQUEST\npath: ${error.requestOptions.path}\nheaders:${error.requestOptions.headers}"
              "queryParameters: ${error.requestOptions.queryParameters}\ndata: ${error.requestOptions.data}\n\n "
              "RESPONSE\nstatusCode: ${error.response?.statusCode}\ndata: ${error.response?.data}");

          return handler.next(error);
        }
    ));

    _request = THRequest(_dio);
    _refreshTokenRequest = THRequest(_tokenDio);
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

    if (thResponse.code == 401) {
      _refreshTokenFuture ??= _refreshTokenRequest!.get(_refreshTokenPath);
      THResponse<Map<String, dynamic>> _refreshTokenResponse = await _refreshTokenFuture!;

      _refreshTokenFuture = null;
      Map<String, dynamic>? refreshTokenData = _refreshTokenResponse.data;
      if (_refreshTokenResponse.code == 200 &&
          refreshTokenData != null &&
          refreshTokenData['access_token'] != null &&
          refreshTokenData['refresh_token'] != null) {
        setToken(_refreshTokenResponse.data?['access_token'], _refreshTokenResponse.data?['refresh_token']);
        return _fetch(method, path, queryParameters: queryParameters, data: data, options: options);
      }
      _notifyListeners();
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