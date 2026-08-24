// This is a generated file - do not edit.
//
// Generated from doubao_ime_asr.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

import 'doubao_ime_asr.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'doubao_ime_asr.pbenum.dart';

class AsrRequest extends $pb.GeneratedMessage {
  factory AsrRequest({
    $core.String? token,
    $core.String? serviceName,
    $core.String? methodName,
    $core.String? payload,
    $core.List<$core.int>? audioData,
    $core.String? requestId,
    FrameState? frameState,
  }) {
    final result = create();
    if (token != null) result.token = token;
    if (serviceName != null) result.serviceName = serviceName;
    if (methodName != null) result.methodName = methodName;
    if (payload != null) result.payload = payload;
    if (audioData != null) result.audioData = audioData;
    if (requestId != null) result.requestId = requestId;
    if (frameState != null) result.frameState = frameState;
    return result;
  }

  AsrRequest._();

  factory AsrRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory AsrRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AsrRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'doubao_ime_asr'),
      createEmptyInstance: create)
    ..aOS(2, _omitFieldNames ? '' : 'token')
    ..aOS(3, _omitFieldNames ? '' : 'serviceName')
    ..aOS(5, _omitFieldNames ? '' : 'methodName')
    ..aOS(6, _omitFieldNames ? '' : 'payload')
    ..a<$core.List<$core.int>>(
        7, _omitFieldNames ? '' : 'audioData', $pb.PbFieldType.OY)
    ..aOS(8, _omitFieldNames ? '' : 'requestId')
    ..aE<FrameState>(9, _omitFieldNames ? '' : 'frameState',
        enumValues: FrameState.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AsrRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AsrRequest copyWith(void Function(AsrRequest) updates) =>
      super.copyWith((message) => updates(message as AsrRequest)) as AsrRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static AsrRequest create() => AsrRequest._();
  @$core.override
  AsrRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static AsrRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AsrRequest>(create);
  static AsrRequest? _defaultInstance;

  @$pb.TagNumber(2)
  $core.String get token => $_getSZ(0);
  @$pb.TagNumber(2)
  set token($core.String value) => $_setString(0, value);
  @$pb.TagNumber(2)
  $core.bool hasToken() => $_has(0);
  @$pb.TagNumber(2)
  void clearToken() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get serviceName => $_getSZ(1);
  @$pb.TagNumber(3)
  set serviceName($core.String value) => $_setString(1, value);
  @$pb.TagNumber(3)
  $core.bool hasServiceName() => $_has(1);
  @$pb.TagNumber(3)
  void clearServiceName() => $_clearField(3);

  @$pb.TagNumber(5)
  $core.String get methodName => $_getSZ(2);
  @$pb.TagNumber(5)
  set methodName($core.String value) => $_setString(2, value);
  @$pb.TagNumber(5)
  $core.bool hasMethodName() => $_has(2);
  @$pb.TagNumber(5)
  void clearMethodName() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.String get payload => $_getSZ(3);
  @$pb.TagNumber(6)
  set payload($core.String value) => $_setString(3, value);
  @$pb.TagNumber(6)
  $core.bool hasPayload() => $_has(3);
  @$pb.TagNumber(6)
  void clearPayload() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.List<$core.int> get audioData => $_getN(4);
  @$pb.TagNumber(7)
  set audioData($core.List<$core.int> value) => $_setBytes(4, value);
  @$pb.TagNumber(7)
  $core.bool hasAudioData() => $_has(4);
  @$pb.TagNumber(7)
  void clearAudioData() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.String get requestId => $_getSZ(5);
  @$pb.TagNumber(8)
  set requestId($core.String value) => $_setString(5, value);
  @$pb.TagNumber(8)
  $core.bool hasRequestId() => $_has(5);
  @$pb.TagNumber(8)
  void clearRequestId() => $_clearField(8);

  @$pb.TagNumber(9)
  FrameState get frameState => $_getN(6);
  @$pb.TagNumber(9)
  set frameState(FrameState value) => $_setField(9, value);
  @$pb.TagNumber(9)
  $core.bool hasFrameState() => $_has(6);
  @$pb.TagNumber(9)
  void clearFrameState() => $_clearField(9);
}

class AsrResponse extends $pb.GeneratedMessage {
  factory AsrResponse({
    $core.String? requestId,
    $core.String? taskId,
    $core.String? serviceName,
    $core.String? messageType,
    $core.int? statusCode,
    $core.String? statusMessage,
    $core.String? resultJson,
    $core.int? unknownField9,
  }) {
    final result = create();
    if (requestId != null) result.requestId = requestId;
    if (taskId != null) result.taskId = taskId;
    if (serviceName != null) result.serviceName = serviceName;
    if (messageType != null) result.messageType = messageType;
    if (statusCode != null) result.statusCode = statusCode;
    if (statusMessage != null) result.statusMessage = statusMessage;
    if (resultJson != null) result.resultJson = resultJson;
    if (unknownField9 != null) result.unknownField9 = unknownField9;
    return result;
  }

  AsrResponse._();

  factory AsrResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory AsrResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AsrResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'doubao_ime_asr'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'requestId')
    ..aOS(2, _omitFieldNames ? '' : 'taskId')
    ..aOS(3, _omitFieldNames ? '' : 'serviceName')
    ..aOS(4, _omitFieldNames ? '' : 'messageType')
    ..aI(5, _omitFieldNames ? '' : 'statusCode')
    ..aOS(6, _omitFieldNames ? '' : 'statusMessage')
    ..aOS(7, _omitFieldNames ? '' : 'resultJson')
    ..aI(9, _omitFieldNames ? '' : 'unknownField9',
        protoName: 'unknown_field_9')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AsrResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AsrResponse copyWith(void Function(AsrResponse) updates) =>
      super.copyWith((message) => updates(message as AsrResponse))
          as AsrResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static AsrResponse create() => AsrResponse._();
  @$core.override
  AsrResponse createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static AsrResponse getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AsrResponse>(create);
  static AsrResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get requestId => $_getSZ(0);
  @$pb.TagNumber(1)
  set requestId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasRequestId() => $_has(0);
  @$pb.TagNumber(1)
  void clearRequestId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get taskId => $_getSZ(1);
  @$pb.TagNumber(2)
  set taskId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasTaskId() => $_has(1);
  @$pb.TagNumber(2)
  void clearTaskId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get serviceName => $_getSZ(2);
  @$pb.TagNumber(3)
  set serviceName($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasServiceName() => $_has(2);
  @$pb.TagNumber(3)
  void clearServiceName() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get messageType => $_getSZ(3);
  @$pb.TagNumber(4)
  set messageType($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMessageType() => $_has(3);
  @$pb.TagNumber(4)
  void clearMessageType() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get statusCode => $_getIZ(4);
  @$pb.TagNumber(5)
  set statusCode($core.int value) => $_setSignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasStatusCode() => $_has(4);
  @$pb.TagNumber(5)
  void clearStatusCode() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.String get statusMessage => $_getSZ(5);
  @$pb.TagNumber(6)
  set statusMessage($core.String value) => $_setString(5, value);
  @$pb.TagNumber(6)
  $core.bool hasStatusMessage() => $_has(5);
  @$pb.TagNumber(6)
  void clearStatusMessage() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.String get resultJson => $_getSZ(6);
  @$pb.TagNumber(7)
  set resultJson($core.String value) => $_setString(6, value);
  @$pb.TagNumber(7)
  $core.bool hasResultJson() => $_has(6);
  @$pb.TagNumber(7)
  void clearResultJson() => $_clearField(7);

  @$pb.TagNumber(9)
  $core.int get unknownField9 => $_getIZ(7);
  @$pb.TagNumber(9)
  set unknownField9($core.int value) => $_setSignedInt32(7, value);
  @$pb.TagNumber(9)
  $core.bool hasUnknownField9() => $_has(7);
  @$pb.TagNumber(9)
  void clearUnknownField9() => $_clearField(9);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
