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

class FrameState extends $pb.ProtobufEnum {
  static const FrameState FRAME_STATE_UNSPECIFIED =
      FrameState._(0, _omitEnumNames ? '' : 'FRAME_STATE_UNSPECIFIED');
  static const FrameState FRAME_STATE_FIRST =
      FrameState._(1, _omitEnumNames ? '' : 'FRAME_STATE_FIRST');
  static const FrameState FRAME_STATE_MIDDLE =
      FrameState._(3, _omitEnumNames ? '' : 'FRAME_STATE_MIDDLE');
  static const FrameState FRAME_STATE_LAST =
      FrameState._(9, _omitEnumNames ? '' : 'FRAME_STATE_LAST');

  static const $core.List<FrameState> values = <FrameState>[
    FRAME_STATE_UNSPECIFIED,
    FRAME_STATE_FIRST,
    FRAME_STATE_MIDDLE,
    FRAME_STATE_LAST,
  ];

  static final $core.Map<$core.int, FrameState> _byValue =
      $pb.ProtobufEnum.initByValue(values);
  static FrameState? valueOf($core.int value) => _byValue[value];

  const FrameState._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
