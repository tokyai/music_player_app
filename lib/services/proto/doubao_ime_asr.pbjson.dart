// This is a generated file - do not edit.
//
// Generated from doubao_ime_asr.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use frameStateDescriptor instead')
const FrameState$json = {
  '1': 'FrameState',
  '2': [
    {'1': 'FRAME_STATE_UNSPECIFIED', '2': 0},
    {'1': 'FRAME_STATE_FIRST', '2': 1},
    {'1': 'FRAME_STATE_MIDDLE', '2': 3},
    {'1': 'FRAME_STATE_LAST', '2': 9},
  ],
};

/// Descriptor for `FrameState`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List frameStateDescriptor = $convert.base64Decode(
    'CgpGcmFtZVN0YXRlEhsKF0ZSQU1FX1NUQVRFX1VOU1BFQ0lGSUVEEAASFQoRRlJBTUVfU1RBVE'
    'VfRklSU1QQARIWChJGUkFNRV9TVEFURV9NSURETEUQAxIUChBGUkFNRV9TVEFURV9MQVNUEAk=');

@$core.Deprecated('Use asrRequestDescriptor instead')
const AsrRequest$json = {
  '1': 'AsrRequest',
  '2': [
    {'1': 'token', '3': 2, '4': 1, '5': 9, '10': 'token'},
    {'1': 'service_name', '3': 3, '4': 1, '5': 9, '10': 'serviceName'},
    {'1': 'method_name', '3': 5, '4': 1, '5': 9, '10': 'methodName'},
    {'1': 'payload', '3': 6, '4': 1, '5': 9, '10': 'payload'},
    {'1': 'audio_data', '3': 7, '4': 1, '5': 12, '10': 'audioData'},
    {'1': 'request_id', '3': 8, '4': 1, '5': 9, '10': 'requestId'},
    {
      '1': 'frame_state',
      '3': 9,
      '4': 1,
      '5': 14,
      '6': '.doubao_ime_asr.FrameState',
      '10': 'frameState'
    },
  ],
};

/// Descriptor for `AsrRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List asrRequestDescriptor = $convert.base64Decode(
    'CgpBc3JSZXF1ZXN0EhQKBXRva2VuGAIgASgJUgV0b2tlbhIhCgxzZXJ2aWNlX25hbWUYAyABKA'
    'lSC3NlcnZpY2VOYW1lEh8KC21ldGhvZF9uYW1lGAUgASgJUgptZXRob2ROYW1lEhgKB3BheWxv'
    'YWQYBiABKAlSB3BheWxvYWQSHQoKYXVkaW9fZGF0YRgHIAEoDFIJYXVkaW9EYXRhEh0KCnJlcX'
    'Vlc3RfaWQYCCABKAlSCXJlcXVlc3RJZBI7CgtmcmFtZV9zdGF0ZRgJIAEoDjIaLmRvdWJhb19p'
    'bWVfYXNyLkZyYW1lU3RhdGVSCmZyYW1lU3RhdGU=');

@$core.Deprecated('Use asrResponseDescriptor instead')
const AsrResponse$json = {
  '1': 'AsrResponse',
  '2': [
    {'1': 'request_id', '3': 1, '4': 1, '5': 9, '10': 'requestId'},
    {'1': 'task_id', '3': 2, '4': 1, '5': 9, '10': 'taskId'},
    {'1': 'service_name', '3': 3, '4': 1, '5': 9, '10': 'serviceName'},
    {'1': 'message_type', '3': 4, '4': 1, '5': 9, '10': 'messageType'},
    {'1': 'status_code', '3': 5, '4': 1, '5': 5, '10': 'statusCode'},
    {'1': 'status_message', '3': 6, '4': 1, '5': 9, '10': 'statusMessage'},
    {'1': 'result_json', '3': 7, '4': 1, '5': 9, '10': 'resultJson'},
    {'1': 'unknown_field_9', '3': 9, '4': 1, '5': 5, '10': 'unknownField9'},
  ],
};

/// Descriptor for `AsrResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List asrResponseDescriptor = $convert.base64Decode(
    'CgtBc3JSZXNwb25zZRIdCgpyZXF1ZXN0X2lkGAEgASgJUglyZXF1ZXN0SWQSFwoHdGFza19pZB'
    'gCIAEoCVIGdGFza0lkEiEKDHNlcnZpY2VfbmFtZRgDIAEoCVILc2VydmljZU5hbWUSIQoMbWVz'
    'c2FnZV90eXBlGAQgASgJUgttZXNzYWdlVHlwZRIfCgtzdGF0dXNfY29kZRgFIAEoBVIKc3RhdH'
    'VzQ29kZRIlCg5zdGF0dXNfbWVzc2FnZRgGIAEoCVINc3RhdHVzTWVzc2FnZRIfCgtyZXN1bHRf'
    'anNvbhgHIAEoCVIKcmVzdWx0SnNvbhImCg91bmtub3duX2ZpZWxkXzkYCSABKAVSDXVua25vd2'
    '5GaWVsZDk=');
