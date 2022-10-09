
import 'package:dio/dio.dart';
import 'package:th_dependencies/th_dependencies.dart';

import '../common/common.dart';

class THResponse<T> {
  THResponse({this.code = 200, this.status = false, this.data, this.message});
  int? code;
  bool? status;
  T? data;
  String? message;//error message

  ///Whether this response object is success or not
  bool get success => status == true && code == 200;

  factory THResponse.fromJson(Response? response) {
    if (response == null) return THResponse.somethingWentWrong();
    try {
      return THResponse(
        code: response.statusCode,
        status: response.data['status'],
        data: response.data['data'],
        message: response.data['message']
      );
    }
    catch (exception) {
      return THResponse.somethingWentWrong();
    }
  }

  factory THResponse.somethingWentWrong() {
    return THResponse(
      code: THErrorCodeClient.somethingWentWrong,
      message: tr(THErrorMessageKey.somethingWentWrong)
    );
  }


  THResponse<Obj> clone<Obj>({Obj? data}) {
    return THResponse<Obj>(
      status: status,
      code: code,
      data: data,
      message: message
    );
  }
}