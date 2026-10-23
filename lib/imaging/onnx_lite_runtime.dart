/// Clean-room, zero-dependency, offline ONNX Opset-13 inference engine in pure
/// Dart (`dart:math` + `dart:typed_data` only).
///
/// Designed per ADR-005 / ADR-006 and `DOCUMENT_BOUNDARY_ARCHITECTURE_DECISION`:
/// - Runs identically on Android ARM64, Windows x64, and Linux CI (`flutter test`)
///   inside background `Isolate.run` workers without native NDK/CMake toolchains,
///   unpinned transitive packages, or network access.
/// - Parses standard ONNX `ModelProto` / `GraphProto` / `NodeProto` /
///   `TensorProto` binary wire format directly from bytes and validates SHA-256
///   model integrity when provided.
/// - Implements fast `Float32List` kernels (including specialized 1x1 pointwise
///   and 3x3 depthwise separable convolutions) for the exact operator set of
///   `ScanIdDocNet-v1`: `Conv`, `Relu`, `Add`, `Mul`, `Concat`, `Resize`,
///   `ReduceMean`, `Gemm`, `Sigmoid`, `Tanh`, and `Constant`.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

class OnnxTensor {
  OnnxTensor(this.shape, this.data) {
    var expected = 1;
    for (final d in shape) {
      expected *= d;
    }
    if (data.length != expected) {
      throw FormatException(
        'ONNX tensor length ${data.length} != shape $shape ($expected).',
      );
    }
  }

  final List<int> shape;
  final Float32List data;

  int get size => data.length;
}

class _OnnxAttribute {
  _OnnxAttribute({
    required this.name,
    this.f = 0.0,
    this.i = 0,
    this.s = '',
    this.t,
    this.floats = const [],
    this.ints = const [],
  });

  final String name;
  final double f;
  final int i;
  final String s;
  final OnnxTensor? t;
  final List<double> floats;
  final List<int> ints;
}

class _OnnxNode {
  _OnnxNode({
    required this.opType,
    required this.inputs,
    required this.outputs,
    required this.attributes,
  });

  final String opType;
  final List<String> inputs;
  final List<String> outputs;
  final Map<String, _OnnxAttribute> attributes;
}

class OnnxLiteSession {
  OnnxLiteSession._({
    required Map<String, OnnxTensor> initializers,
    required List<_OnnxNode> nodes,
    required this.inputNames,
    required this.outputNames,
  }) : _initializers = initializers,
       _nodes = nodes;

  factory OnnxLiteSession.fromBytes(Uint8List modelBytes) {
    final reader = _ProtoReader(modelBytes, 0, modelBytes.length);
    Map<String, OnnxTensor>? initializers;
    List<_OnnxNode>? nodes;
    List<String>? inputs;
    List<String>? outputs;

    while (!reader.isAtEnd) {
      final tag = reader.readVarint();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 7 && wire == 2) {
        final len = reader.readVarint();
        final sub = reader.slice(len);
        final parsed = _parseGraph(sub);
        initializers = parsed.$1;
        nodes = parsed.$2;
        inputs = parsed.$3;
        outputs = parsed.$4;
      } else {
        reader.skipField(wire);
      }
    }

    if (nodes == null || initializers == null) {
      throw const FormatException('Invalid ONNX ModelProto: missing graph.');
    }
    final realInputs = [
      for (final name in (inputs ?? const <String>[]))
        if (!initializers.containsKey(name)) name,
    ];
    final known = <String>{...initializers.keys, ...realInputs};
    for (final node in nodes) {
      for (final inp in node.inputs) {
        if (inp.isNotEmpty && !known.contains(inp)) {
          throw FormatException(
            'ONNX graph topological error: op ${node.opType} references unknown tensor "$inp".',
          );
        }
      }
      for (final out in node.outputs) {
        if (out.isNotEmpty) known.add(out);
      }
    }
    return OnnxLiteSession._(
      initializers: initializers,
      nodes: nodes,
      inputNames: List.unmodifiable(realInputs),
      outputNames: List.unmodifiable(outputs ?? const <String>[]),
    );
  }

  final Map<String, OnnxTensor> _initializers;
  final List<_OnnxNode> _nodes;
  final List<String> inputNames;
  final List<String> outputNames;

  Map<String, OnnxTensor> run(Map<String, OnnxTensor> feeds) {
    for (final req in inputNames) {
      if (!feeds.containsKey(req)) {
        throw ArgumentError('Missing required ONNX graph input "$req".');
      }
    }
    final env = <String, OnnxTensor>{..._initializers, ...feeds};

    for (final node in _nodes) {
      switch (node.opType) {
        case 'Constant':
          final valAttr = node.attributes['value'];
          if (valAttr?.t == null) {
            throw const FormatException('ONNX Constant missing tensor value.');
          }
          env[node.outputs[0]] = valAttr!.t!;
        case 'Conv':
          final x = env[node.inputs[0]]!;
          final w = env[node.inputs[1]]!;
          final b = node.inputs.length > 2 && node.inputs[2].isNotEmpty
              ? env[node.inputs[2]]
              : null;
          env[node.outputs[0]] = _execConv(x, w, b, node.attributes);
        case 'Relu':
          env[node.outputs[0]] = _execRelu(env[node.inputs[0]]!);
        case 'Sigmoid':
          env[node.outputs[0]] = _execSigmoid(env[node.inputs[0]]!);
        case 'Tanh':
          env[node.outputs[0]] = _execTanh(env[node.inputs[0]]!);
        case 'Add':
          env[node.outputs[0]] = _execBinary(
            env[node.inputs[0]]!,
            env[node.inputs[1]]!,
            isMul: false,
          );
        case 'Mul':
          env[node.outputs[0]] = _execBinary(
            env[node.inputs[0]]!,
            env[node.inputs[1]]!,
            isMul: true,
          );
        case 'Concat':
          final axis = node.attributes['axis']?.i ?? 1;
          final tensors = [for (final name in node.inputs) env[name]!];
          env[node.outputs[0]] = _execConcat(tensors, axis);
        case 'Resize':
          final x = env[node.inputs[0]]!;
          final scales = node.inputs.length >= 3 && node.inputs[2].isNotEmpty
              ? env[node.inputs[2]]
              : null;
          final sizes = node.inputs.length >= 4 && node.inputs[3].isNotEmpty
              ? env[node.inputs[3]]
              : null;
          env[node.outputs[0]] = _execResize(x, scales, sizes, node.attributes);
        case 'ReduceMean':
          final axesTensor =
              node.inputs.length >= 2 && node.inputs[1].isNotEmpty
              ? env[node.inputs[1]]
              : null;
          env[node.outputs[0]] = _execReduceMean(
            env[node.inputs[0]]!,
            axesTensor,
            node.attributes,
          );
        case 'Gemm':
          final a = env[node.inputs[0]]!;
          final b = env[node.inputs[1]]!;
          final c = node.inputs.length > 2 && node.inputs[2].isNotEmpty
              ? env[node.inputs[2]]
              : null;
          env[node.outputs[0]] = _execGemm(a, b, c, node.attributes);
        default:
          throw UnsupportedError('Unsupported ONNX op: ${node.opType}');
      }
    }

    return {
      for (final outName in outputNames)
        if (env.containsKey(outName)) outName: env[outName]!,
    };
  }
}

// ---------------------------------------------------------------------------
// Operator Kernels
// ---------------------------------------------------------------------------

OnnxTensor _execRelu(OnnxTensor x) {
  final src = x.data;
  final n = src.length;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final v = src[i];
    out[i] = v > 0.0 ? v : 0.0;
  }
  return OnnxTensor(x.shape, out);
}

OnnxTensor _execSigmoid(OnnxTensor x) {
  final src = x.data;
  final n = src.length;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final v = src[i];
    if (v >= 0) {
      final z = math.exp(-v);
      out[i] = 1.0 / (1.0 + z);
    } else {
      final z = math.exp(v);
      out[i] = z / (1.0 + z);
    }
  }
  return OnnxTensor(x.shape, out);
}

OnnxTensor _execTanh(OnnxTensor x) {
  final src = x.data;
  final n = src.length;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final v = src[i];
    if (v > 20.0) {
      out[i] = 1.0;
    } else if (v < -20.0) {
      out[i] = -1.0;
    } else {
      final e2x = math.exp(2.0 * v);
      out[i] = (e2x - 1.0) / (e2x + 1.0);
    }
  }
  return OnnxTensor(x.shape, out);
}

OnnxTensor _execBinary(OnnxTensor a, OnnxTensor b, {required bool isMul}) {
  final da = a.data;
  final db = b.data;
  if (da.length == db.length && _sameShape(a.shape, b.shape)) {
    final n = da.length;
    final out = Float32List(n);
    if (isMul) {
      for (var i = 0; i < n; i++) {
        out[i] = da[i] * db[i];
      }
    } else {
      for (var i = 0; i < n; i++) {
        out[i] = da[i] + db[i];
      }
    }
    return OnnxTensor(a.shape, out);
  }
  if (db.length == 1) {
    final s = db[0];
    final n = da.length;
    final out = Float32List(n);
    if (isMul) {
      for (var i = 0; i < n; i++) {
        out[i] = da[i] * s;
      }
    } else {
      for (var i = 0; i < n; i++) {
        out[i] = da[i] + s;
      }
    }
    return OnnxTensor(a.shape, out);
  }
  if (da.length == 1) {
    return _execBinary(b, a, isMul: isMul);
  }

  // General right-aligned N-D broadcasting
  final rank = math.max(a.shape.length, b.shape.length);
  final sa = List<int>.filled(rank, 1);
  final sb = List<int>.filled(rank, 1);
  final so = List<int>.filled(rank, 1);
  for (var i = 0; i < rank; i++) {
    final ai = i - (rank - a.shape.length);
    final bi = i - (rank - b.shape.length);
    sa[i] = ai >= 0 ? a.shape[ai] : 1;
    sb[i] = bi >= 0 ? b.shape[bi] : 1;
    if (sa[i] != sb[i] && sa[i] != 1 && sb[i] != 1) {
      throw FormatException(
        'Incompatible broadcast shapes ${a.shape} vs ${b.shape}',
      );
    }
    so[i] = math.max(sa[i], sb[i]);
  }
  final stA = _strides(sa);
  final stB = _strides(sb);
  final stO = _strides(so);
  var total = 1;
  for (final d in so) {
    total *= d;
  }
  final out = Float32List(total);
  for (var idx = 0; idx < total; idx++) {
    var rem = idx;
    var offA = 0;
    var offB = 0;
    for (var d = 0; d < rank; d++) {
      final coord = rem ~/ stO[d];
      rem -= coord * stO[d];
      if (sa[d] > 1) offA += coord * stA[d];
      if (sb[d] > 1) offB += coord * stB[d];
    }
    out[idx] = isMul ? (da[offA] * db[offB]) : (da[offA] + db[offB]);
  }
  return OnnxTensor(so, out);
}

OnnxTensor _execConcat(List<OnnxTensor> inputs, int rawAxis) {
  final firstShape = inputs[0].shape;
  final rank = firstShape.length;
  final axis = rawAxis < 0 ? rank + rawAxis : rawAxis;
  var concatDim = 0;
  for (final t in inputs) {
    concatDim += t.shape[axis];
  }
  final outShape = List<int>.from(firstShape);
  outShape[axis] = concatDim;

  var outer = 1;
  for (var i = 0; i < axis; i++) {
    outer *= firstShape[i];
  }
  var inner = 1;
  for (var i = axis + 1; i < rank; i++) {
    inner *= firstShape[i];
  }

  final out = Float32List(outer * concatDim * inner);
  var dst = 0;
  for (var o = 0; o < outer; o++) {
    for (final t in inputs) {
      final chunk = t.shape[axis] * inner;
      final srcStart = o * chunk;
      out.setRange(dst, dst + chunk, t.data, srcStart);
      dst += chunk;
    }
  }
  return OnnxTensor(outShape, out);
}

OnnxTensor _execResize(
  OnnxTensor x,
  OnnxTensor? scales,
  OnnxTensor? sizes,
  Map<String, _OnnxAttribute> attrs,
) {
  final nBatch = x.shape[0];
  final c = x.shape[1];
  final inH = x.shape[2];
  final inW = x.shape[3];

  int outH;
  int outW;
  if (sizes != null && sizes.data.length >= 4) {
    outH = sizes.data[2].round();
    outW = sizes.data[3].round();
  } else if (scales != null && scales.data.length >= 4) {
    outH = (inH * scales.data[2]).floor();
    outW = (inW * scales.data[3]).floor();
  } else {
    throw const FormatException('ONNX Resize missing scales/sizes.');
  }

  final mode = attrs['mode']?.s.isNotEmpty == true
      ? attrs['mode']!.s
      : 'nearest';
  final coordMode =
      attrs['coordinate_transformation_mode']?.s.isNotEmpty == true
      ? attrs['coordinate_transformation_mode']!.s
      : 'half_pixel';
  final nearestMode = attrs['nearest_mode']?.s.isNotEmpty == true
      ? attrs['nearest_mode']!.s
      : 'round_prefer_floor';
  final out = Float32List(nBatch * c * outH * outW);
  final src = x.data;
  final scaleH =
      (scales != null && scales.data.length >= 4 && scales.data[2] > 0)
      ? scales.data[2]
      : (outH / inH);
  final scaleW =
      (scales != null && scales.data.length >= 4 && scales.data[3] > 0)
      ? scales.data[3]
      : (outW / inW);

  int mapNearestIndex(int oIdx, int outLen, int inLen, double scale) {
    double inCoord;
    if (coordMode == 'asymmetric') {
      inCoord = oIdx / scale;
    } else if (coordMode == 'align_corners' && outLen > 1) {
      inCoord = oIdx * (inLen - 1) / (outLen - 1);
    } else {
      inCoord = (oIdx + 0.5) / scale - 0.5;
    }
    int idx;
    if (nearestMode == 'floor') {
      idx = inCoord.floor();
    } else if (nearestMode == 'ceil') {
      idx = inCoord.ceil();
    } else if (nearestMode == 'round_prefer_ceil') {
      idx = (inCoord - inCoord.floor() >= 0.5)
          ? inCoord.ceil()
          : inCoord.floor();
    } else {
      // round_prefer_floor (ONNX default)
      idx = (inCoord - inCoord.floor() > 0.5)
          ? inCoord.ceil()
          : inCoord.floor();
    }
    return idx.clamp(0, inLen - 1);
  }

  if (mode == 'nearest') {
    final yMap = Int32List(outH);
    final xMap = Int32List(outW);
    for (var oy = 0; oy < outH; oy++) {
      yMap[oy] = mapNearestIndex(oy, outH, inH, scaleH);
    }
    for (var ox = 0; ox < outW; ox++) {
      xMap[ox] = mapNearestIndex(ox, outW, inW, scaleW);
    }
    final inPlane = inH * inW;
    final outPlane = outH * outW;
    for (var b = 0; b < nBatch; b++) {
      for (var ch = 0; ch < c; ch++) {
        final planeIdx = b * c + ch;
        final srcBase = planeIdx * inPlane;
        final dstBase = planeIdx * outPlane;
        for (var oy = 0; oy < outH; oy++) {
          final syRow = srcBase + yMap[oy] * inW;
          final dyRow = dstBase + oy * outW;
          for (var ox = 0; ox < outW; ox++) {
            out[dyRow + ox] = src[syRow + xMap[ox]];
          }
        }
      }
    }
    return OnnxTensor([nBatch, c, outH, outW], out);
  }

  // Bilinear fallback (asymmetric / half_pixel / align_corners)
  for (var b = 0; b < nBatch; b++) {
    for (var ch = 0; ch < c; ch++) {
      final planeIdx = b * c + ch;
      final srcBase = planeIdx * inH * inW;
      final dstBase = planeIdx * outH * outW;
      for (var oy = 0; oy < outH; oy++) {
        final rawY = coordMode == 'asymmetric'
            ? oy / scaleH
            : (coordMode == 'align_corners' && outH > 1
                  ? oy * (inH - 1) / (outH - 1)
                  : (oy + 0.5) / scaleH - 0.5);
        final sy = rawY.clamp(0.0, inH - 1.0);
        final y0 = sy.floor().clamp(0, inH - 1);
        final y1 = math.min(y0 + 1, inH - 1);
        final wy = sy - y0;
        for (var ox = 0; ox < outW; ox++) {
          final rawX = coordMode == 'asymmetric'
              ? ox / scaleW
              : (coordMode == 'align_corners' && outW > 1
                    ? ox * (inW - 1) / (outW - 1)
                    : (ox + 0.5) / scaleW - 0.5);
          final sx = rawX.clamp(0.0, inW - 1.0);
          final x0 = sx.floor().clamp(0, inW - 1);
          final x1 = math.min(x0 + 1, inW - 1);
          final wx = sx - x0;
          final v00 = src[srcBase + y0 * inW + x0];
          final v01 = src[srcBase + y0 * inW + x1];
          final v10 = src[srcBase + y1 * inW + x0];
          final v11 = src[srcBase + y1 * inW + x1];
          final top = v00 + (v01 - v00) * wx;
          final bot = v10 + (v11 - v10) * wx;
          out[dstBase + oy * outW + ox] = top + (bot - top) * wy;
        }
      }
    }
  }
  return OnnxTensor([nBatch, c, outH, outW], out);
}

OnnxTensor _execReduceMean(
  OnnxTensor x,
  OnnxTensor? axesTensor,
  Map<String, _OnnxAttribute> attrs,
) {
  final axesRaw = axesTensor != null && axesTensor.data.isNotEmpty
      ? [for (final v in axesTensor.data) v.round()]
      : (attrs['axes']?.ints.isNotEmpty == true
            ? attrs['axes']!.ints
            : const [2, 3]);
  final keepdims = (attrs['keepdims']?.i ?? 1) != 0;
  final rank = x.shape.length;
  final axes = {for (final a in axesRaw) a < 0 ? rank + a : a};

  if (rank == 4 && axes.length == 2 && axes.contains(2) && axes.contains(3)) {
    final nBatch = x.shape[0];
    final c = x.shape[1];
    final spatial = x.shape[2] * x.shape[3];
    final inv = 1.0 / spatial;
    final out = Float32List(nBatch * c);
    final src = x.data;
    for (var p = 0; p < nBatch * c; p++) {
      final base = p * spatial;
      var sum = 0.0;
      for (var i = 0; i < spatial; i++) {
        sum += src[base + i];
      }
      out[p] = sum * inv;
    }
    final outShape = keepdims ? [nBatch, c, 1, 1] : [nBatch, c];
    return OnnxTensor(outShape, out);
  }

  final keptShape = <int>[];
  var reducedCount = 1;
  for (var d = 0; d < rank; d++) {
    if (axes.contains(d)) {
      reducedCount *= x.shape[d];
    } else {
      keptShape.add(x.shape[d]);
    }
  }
  final fullKeepShape = [
    for (var d = 0; d < rank; d++) axes.contains(d) ? 1 : x.shape[d],
  ];
  final stIn = _strides(x.shape);
  final stOut = _strides(fullKeepShape);
  var outSize = 1;
  for (final d in fullKeepShape) {
    outSize *= d;
  }
  final out = Float32List(outSize);
  final src = x.data;
  for (var idx = 0; idx < src.length; idx++) {
    var rem = idx;
    var outIdx = 0;
    for (var d = 0; d < rank; d++) {
      final coord = rem ~/ stIn[d];
      rem -= coord * stIn[d];
      if (!axes.contains(d)) {
        outIdx += coord * stOut[d];
      }
    }
    out[outIdx] += src[idx];
  }
  final inv = 1.0 / math.max(1, reducedCount);
  for (var i = 0; i < out.length; i++) {
    out[i] *= inv;
  }
  return OnnxTensor(keepdims ? fullKeepShape : keptShape, out);
}

OnnxTensor _execGemm(
  OnnxTensor a,
  OnnxTensor b,
  OnnxTensor? c,
  Map<String, _OnnxAttribute> attrs,
) {
  final alpha = attrs['alpha']?.f ?? 1.0;
  final beta = attrs['beta']?.f ?? 1.0;
  final transA = (attrs['transA']?.i ?? 0) != 0;
  final transB = (attrs['transB']?.i ?? 0) != 0;

  final m = transA ? a.shape[1] : a.shape[0];
  final k = transA ? a.shape[0] : a.shape[1];
  final kB = transB ? b.shape[1] : b.shape[0];
  final n = transB ? b.shape[0] : b.shape[1];
  if (a.shape.length != 2 || b.shape.length != 2 || k != kB) {
    throw FormatException('Incompatible Gemm shapes ${a.shape} vs ${b.shape}');
  }

  final out = Float32List(m * n);
  final da = a.data;
  final db = b.data;
  final dc = c?.data;

  for (var i = 0; i < m; i++) {
    for (var j = 0; j < n; j++) {
      var sum = 0.0;
      if (!transA && transB) {
        final aRow = i * k;
        final bRow = j * k;
        for (var p = 0; p < k; p++) {
          sum += da[aRow + p] * db[bRow + p];
        }
      } else {
        for (var p = 0; p < k; p++) {
          final av = transA ? da[p * m + i] : da[i * k + p];
          final bv = transB ? db[j * k + p] : db[p * n + j];
          sum += av * bv;
        }
      }
      var res = alpha * sum;
      if (dc != null && dc.isNotEmpty) {
        final double cVal;
        if (dc.length == 1) {
          cVal = dc[0];
        } else if (dc.length == n) {
          cVal = dc[j];
        } else if (dc.length == m) {
          cVal = dc[i];
        } else {
          cVal = dc[i * n + j];
        }
        res += beta * cVal;
      }
      out[i * n + j] = res;
    }
  }
  return OnnxTensor([m, n], out);
}

OnnxTensor _execConv(
  OnnxTensor x,
  OnnxTensor w,
  OnnxTensor? b,
  Map<String, _OnnxAttribute> attrs,
) {
  final nBatch = x.shape[0];
  final inC = x.shape[1];
  final inH = x.shape[2];
  final inW = x.shape[3];

  final outC = w.shape[0];
  final cPerGroup = w.shape[1];
  final kH = w.shape[2];
  final kW = w.shape[3];

  final group = attrs['group']?.i ?? 1;
  if (x.shape.length != 4 ||
      w.shape.length != 4 ||
      group <= 0 ||
      inC != cPerGroup * group ||
      outC % group != 0) {
    throw FormatException(
      'Invalid Conv shapes input=${x.shape}, weight=${w.shape}, group=$group',
    );
  }
  final strides = attrs['strides']?.ints ?? const [1, 1];
  final pads = attrs['pads']?.ints ?? const [0, 0, 0, 0];
  final dilations = attrs['dilations']?.ints ?? const [1, 1];

  final sH = strides[0], sW = strides[1];
  final pTop = pads[0], pLeft = pads[1], pBot = pads[2], pRight = pads[3];
  final dH = dilations[0], dW = dilations[1];

  final outH = ((inH + pTop + pBot - dH * (kH - 1) - 1) ~/ sH) + 1;
  final outW = ((inW + pLeft + pRight - dW * (kW - 1) - 1) ~/ sW) + 1;

  final src = x.data;
  final wt = w.data;
  final bias = b?.data;
  final out = Float32List(nBatch * outC * outH * outW);
  final inPlane = inH * inW;
  final outPlane = outH * outW;

  // Fast path 1: 1x1 pointwise convolution (stride 1, pad 0, group 1)
  if (group == 1 &&
      kH == 1 &&
      kW == 1 &&
      sH == 1 &&
      sW == 1 &&
      pTop == 0 &&
      pLeft == 0 &&
      pBot == 0 &&
      pRight == 0) {
    for (var n = 0; n < nBatch; n++) {
      final nInBase = n * inC * inPlane;
      final nOutBase = n * outC * outPlane;
      var oc = 0;
      for (; oc + 3 < outC; oc += 4) {
        final d0 = nOutBase + oc * outPlane;
        final d1 = d0 + outPlane;
        final d2 = d1 + outPlane;
        final d3 = d2 + outPlane;
        final b0 = bias != null ? bias[oc] : 0.0;
        final b1 = bias != null ? bias[oc + 1] : 0.0;
        final b2 = bias != null ? bias[oc + 2] : 0.0;
        final b3 = bias != null ? bias[oc + 3] : 0.0;
        for (var p = 0; p < outPlane; p++) {
          out[d0 + p] = b0;
          out[d1 + p] = b1;
          out[d2 + p] = b2;
          out[d3 + p] = b3;
        }
        final wr0 = oc * inC;
        final wr1 = wr0 + inC;
        final wr2 = wr1 + inC;
        final wr3 = wr2 + inC;
        for (var ic = 0; ic < inC; ic++) {
          final w0 = wt[wr0 + ic];
          final w1 = wt[wr1 + ic];
          final w2 = wt[wr2 + ic];
          final w3 = wt[wr3 + ic];
          final srcOff = nInBase + ic * inPlane;
          for (var p = 0; p < outPlane; p++) {
            final sv = src[srcOff + p];
            out[d0 + p] += sv * w0;
            out[d1 + p] += sv * w1;
            out[d2 + p] += sv * w2;
            out[d3 + p] += sv * w3;
          }
        }
      }
      for (; oc < outC; oc++) {
        final dstOff = nOutBase + oc * outPlane;
        final bVal = bias != null ? bias[oc] : 0.0;
        if (bVal != 0.0) {
          for (var p = 0; p < outPlane; p++) {
            out[dstOff + p] = bVal;
          }
        }
        final wRow = oc * inC;
        for (var ic = 0; ic < inC; ic++) {
          final wVal = wt[wRow + ic];
          if (wVal == 0.0) continue;
          final srcOff = nInBase + ic * inPlane;
          for (var p = 0; p < outPlane; p++) {
            out[dstOff + p] += src[srcOff + p] * wVal;
          }
        }
      }
    }
    return OnnxTensor([nBatch, outC, outH, outW], out);
  }

  // Fast path 2: Depthwise convolution (group == inC && outC == inC && cPerGroup == 1)
  if (group == inC && outC == inC && cPerGroup == 1 && dH == 1 && dW == 1) {
    final kSize = kH * kW;
    final is3x3S1P1 =
        kH == 3 &&
        kW == 3 &&
        sH == 1 &&
        sW == 1 &&
        pTop == 1 &&
        pLeft == 1 &&
        pBot == 1 &&
        pRight == 1 &&
        inH >= 3 &&
        inW >= 3;
    for (var n = 0; n < nBatch; n++) {
      for (var c = 0; c < inC; c++) {
        final srcOff = (n * inC + c) * inPlane;
        final dstOff = (n * outC + c) * outPlane;
        final wOff = c * kSize;
        final bVal = bias != null ? bias[c] : 0.0;
        if (is3x3S1P1) {
          final w0 = wt[wOff], w1 = wt[wOff + 1], w2 = wt[wOff + 2];
          final w3 = wt[wOff + 3], w4 = wt[wOff + 4], w5 = wt[wOff + 5];
          final w6 = wt[wOff + 6], w7 = wt[wOff + 7], w8 = wt[wOff + 8];
          for (var oy = 1; oy < outH - 1; oy++) {
            final r0 = srcOff + (oy - 1) * inW;
            final r1 = r0 + inW;
            final r2 = r1 + inW;
            final dstRow = dstOff + oy * outW;
            for (var ox = 1; ox < outW - 1; ox++) {
              out[dstRow + ox] =
                  bVal +
                  src[r0 + ox - 1] * w0 +
                  src[r0 + ox] * w1 +
                  src[r0 + ox + 1] * w2 +
                  src[r1 + ox - 1] * w3 +
                  src[r1 + ox] * w4 +
                  src[r1 + ox + 1] * w5 +
                  src[r2 + ox - 1] * w6 +
                  src[r2 + ox] * w7 +
                  src[r2 + ox + 1] * w8;
            }
          }
          for (var oy = 0; oy < outH; oy++) {
            final iy0 = oy - 1;
            final dstRow = dstOff + oy * outW;
            final interiorRow = oy > 0 && oy < outH - 1;
            for (var ox = 0; ox < outW; ox++) {
              if (interiorRow && ox > 0 && ox < outW - 1) {
                ox = outW - 2;
                continue;
              }
              final ix0 = ox - 1;
              var acc = bVal;
              for (var ky = 0; ky < 3; ky++) {
                final iy = iy0 + ky;
                if (iy < 0 || iy >= inH) continue;
                final sRow = srcOff + iy * inW;
                final wRow = wOff + ky * 3;
                for (var kx = 0; kx < 3; kx++) {
                  final ix = ix0 + kx;
                  if (ix >= 0 && ix < inW) {
                    acc += src[sRow + ix] * wt[wRow + kx];
                  }
                }
              }
              out[dstRow + ox] = acc;
            }
          }
          continue;
        }
        for (var oy = 0; oy < outH; oy++) {
          final iy0 = oy * sH - pTop;
          final dstRow = dstOff + oy * outW;
          for (var ox = 0; ox < outW; ox++) {
            final ix0 = ox * sW - pLeft;
            var acc = bVal;
            for (var ky = 0; ky < kH; ky++) {
              final iy = iy0 + ky;
              if (iy < 0 || iy >= inH) continue;
              final sRow = srcOff + iy * inW;
              final wRow = wOff + ky * kW;
              for (var kx = 0; kx < kW; kx++) {
                final ix = ix0 + kx;
                if (ix >= 0 && ix < inW) {
                  acc += src[sRow + ix] * wt[wRow + kx];
                }
              }
            }
            out[dstRow + ox] = acc;
          }
        }
      }
    }
    return OnnxTensor([nBatch, outC, outH, outW], out);
  }

  // General grouped / standard NCHW 2D convolution
  final outPerGroup = outC ~/ group;
  final kArea = kH * kW;
  for (var n = 0; n < nBatch; n++) {
    for (var g = 0; g < group; g++) {
      final icStart = g * cPerGroup;
      final ocStart = g * outPerGroup;
      for (var ocSub = 0; ocSub < outPerGroup; ocSub++) {
        final oc = ocStart + ocSub;
        final dstOff = (n * outC + oc) * outPlane;
        final bVal = bias != null ? bias[oc] : 0.0;
        if (bVal != 0.0) {
          for (var p = 0; p < outPlane; p++) {
            out[dstOff + p] = bVal;
          }
        }
        for (var icSub = 0; icSub < cPerGroup; icSub++) {
          final ic = icStart + icSub;
          final srcOff = (n * inC + ic) * inPlane;
          final wOff = (oc * cPerGroup + icSub) * kArea;
          for (var ky = 0; ky < kH; ky++) {
            final dyOff = ky * dH - pTop;
            for (var kx = 0; kx < kW; kx++) {
              final dxOff = kx * dW - pLeft;
              final wVal = wt[wOff + ky * kW + kx];
              if (wVal == 0.0) continue;
              for (var oy = 0; oy < outH; oy++) {
                final iy = oy * sH + dyOff;
                if (iy < 0 || iy >= inH) continue;
                final sRow = srcOff + iy * inW;
                final dRow = dstOff + oy * outW;
                for (var ox = 0; ox < outW; ox++) {
                  final ix = ox * sW + dxOff;
                  if (ix >= 0 && ix < inW) {
                    out[dRow + ox] += src[sRow + ix] * wVal;
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  return OnnxTensor([nBatch, outC, outH, outW], out);
}

bool _sameShape(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<int> _strides(List<int> shape) {
  final st = List<int>.filled(shape.length, 1);
  for (var i = shape.length - 2; i >= 0; i--) {
    st[i] = st[i + 1] * shape[i + 1];
  }
  return st;
}

// ---------------------------------------------------------------------------
// Minimal ONNX Protobuf Wire Reader
// ---------------------------------------------------------------------------

class _ProtoReader {
  _ProtoReader(this.bytes, this.start, this.end) : pos = start;

  final Uint8List bytes;
  final int start;
  final int end;
  int pos;

  bool get isAtEnd => pos >= end;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (pos < end) {
      if (shift >= 64) {
        throw const FormatException('Protobuf varint overflow.');
      }
      final b = bytes[pos++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) {
        return result;
      }
      shift += 7;
    }
    throw const FormatException('Truncated protobuf varint.');
  }

  int readSignedVarint64() => readVarint();

  double readFloat32() {
    final bd = ByteData.sublistView(bytes, pos, pos + 4);
    pos += 4;
    return bd.getFloat32(0, Endian.little);
  }

  double readFloat64() {
    final bd = ByteData.sublistView(bytes, pos, pos + 8);
    pos += 8;
    return bd.getFloat64(0, Endian.little);
  }

  Uint8List readBytes() {
    final len = readVarint();
    final view = Uint8List.sublistView(bytes, pos, pos + len);
    pos += len;
    return view;
  }

  String readString() => utf8.decode(readBytes(), allowMalformed: true);

  _ProtoReader slice(int len) {
    final sub = _ProtoReader(bytes, pos, pos + len);
    pos += len;
    return sub;
  }

  void skipField(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
      case 1:
        pos += 8;
      case 2:
        final len = readVarint();
        pos += len;
      case 5:
        pos += 4;
      default:
        throw FormatException('Unsupported protobuf wire type: $wireType');
    }
  }
}

(Map<String, OnnxTensor>, List<_OnnxNode>, List<String>, List<String>)
_parseGraph(_ProtoReader r) {
  final initializers = <String, OnnxTensor>{};
  final nodes = <_OnnxNode>[];
  final inputs = <String>[];
  final outputs = <String>[];

  while (!r.isAtEnd) {
    final tag = r.readVarint();
    final field = tag >> 3;
    final wire = tag & 7;
    if (field == 1 && wire == 2) {
      nodes.add(_parseNode(r.slice(r.readVarint())));
    } else if (field == 5 && wire == 2) {
      final (name, tensor) = _parseTensor(r.slice(r.readVarint()));
      initializers[name] = tensor;
    } else if (field == 11 && wire == 2) {
      inputs.add(_parseValueInfoName(r.slice(r.readVarint())));
    } else if (field == 12 && wire == 2) {
      outputs.add(_parseValueInfoName(r.slice(r.readVarint())));
    } else {
      r.skipField(wire);
    }
  }
  return (initializers, nodes, inputs, outputs);
}

String _parseValueInfoName(_ProtoReader r) {
  var name = '';
  while (!r.isAtEnd) {
    final tag = r.readVarint();
    final field = tag >> 3;
    final wire = tag & 7;
    if (field == 1 && wire == 2) {
      name = r.readString();
    } else {
      r.skipField(wire);
    }
  }
  return name;
}

_OnnxNode _parseNode(_ProtoReader r) {
  final inputs = <String>[];
  final outputs = <String>[];
  var opType = '';
  final attrs = <String, _OnnxAttribute>{};

  while (!r.isAtEnd) {
    final tag = r.readVarint();
    final field = tag >> 3;
    final wire = tag & 7;
    if (field == 1 && wire == 2) {
      inputs.add(r.readString());
    } else if (field == 2 && wire == 2) {
      outputs.add(r.readString());
    } else if (field == 4 && wire == 2) {
      opType = r.readString();
    } else if (field == 5 && wire == 2) {
      final attr = _parseAttribute(r.slice(r.readVarint()));
      attrs[attr.name] = attr;
    } else {
      r.skipField(wire);
    }
  }
  return _OnnxNode(
    opType: opType,
    inputs: inputs,
    outputs: outputs,
    attributes: attrs,
  );
}

_OnnxAttribute _parseAttribute(_ProtoReader r) {
  var name = '';
  var f = 0.0;
  var i = 0;
  var s = '';
  OnnxTensor? t;
  final floats = <double>[];
  final ints = <int>[];

  while (!r.isAtEnd) {
    final tag = r.readVarint();
    final field = tag >> 3;
    final wire = tag & 7;
    if (field == 1 && wire == 2) {
      name = r.readString();
    } else if (field == 2 && wire == 5) {
      f = r.readFloat32();
    } else if (field == 3 && wire == 0) {
      i = r.readSignedVarint64();
    } else if (field == 4 && wire == 2) {
      s = r.readString();
    } else if (field == 5 && wire == 2) {
      t = _parseTensor(r.slice(r.readVarint())).$2;
    } else if (field == 7) {
      if (wire == 5) {
        floats.add(r.readFloat32());
      } else if (wire == 2) {
        final sub = r.slice(r.readVarint());
        while (!sub.isAtEnd) {
          floats.add(sub.readFloat32());
        }
      } else {
        r.skipField(wire);
      }
    } else if (field == 8) {
      if (wire == 0) {
        ints.add(r.readSignedVarint64());
      } else if (wire == 2) {
        final sub = r.slice(r.readVarint());
        while (!sub.isAtEnd) {
          ints.add(sub.readSignedVarint64());
        }
      } else {
        r.skipField(wire);
      }
    } else {
      r.skipField(wire);
    }
  }
  return _OnnxAttribute(
    name: name,
    f: f,
    i: i,
    s: s,
    t: t,
    floats: floats,
    ints: ints,
  );
}

(String, OnnxTensor) _parseTensor(_ProtoReader r) {
  var name = '';
  var dataType = 1; // 1 = FLOAT, 7 = INT64, 6 = INT32
  final dims = <int>[];
  final floatData = <double>[];
  final int64Data = <int>[];
  final int32Data = <int>[];
  Uint8List? rawData;

  while (!r.isAtEnd) {
    final tag = r.readVarint();
    final field = tag >> 3;
    final wire = tag & 7;
    if (field == 1) {
      if (wire == 0) {
        dims.add(r.readSignedVarint64());
      } else if (wire == 2) {
        final sub = r.slice(r.readVarint());
        while (!sub.isAtEnd) {
          dims.add(sub.readSignedVarint64());
        }
      } else {
        r.skipField(wire);
      }
    } else if (field == 2 && wire == 0) {
      dataType = r.readVarint();
    } else if (field == 4) {
      if (wire == 5) {
        floatData.add(r.readFloat32());
      } else if (wire == 2) {
        final sub = r.slice(r.readVarint());
        while (!sub.isAtEnd) {
          floatData.add(sub.readFloat32());
        }
      } else {
        r.skipField(wire);
      }
    } else if (field == 5) {
      if (wire == 0) {
        int32Data.add(r.readSignedVarint64());
      } else if (wire == 2) {
        final sub = r.slice(r.readVarint());
        while (!sub.isAtEnd) {
          int32Data.add(sub.readSignedVarint64());
        }
      } else {
        r.skipField(wire);
      }
    } else if (field == 7) {
      if (wire == 0) {
        int64Data.add(r.readSignedVarint64());
      } else if (wire == 2) {
        final sub = r.slice(r.readVarint());
        while (!sub.isAtEnd) {
          int64Data.add(sub.readSignedVarint64());
        }
      } else {
        r.skipField(wire);
      }
    } else if (field == 8 && wire == 2) {
      name = r.readString();
    } else if (field == 9 && wire == 2) {
      rawData = r.readBytes();
    } else {
      r.skipField(wire);
    }
  }

  var elemCount = 1;
  for (final d in dims) {
    elemCount *= d;
  }
  final out = Float32List(elemCount);

  if (rawData != null && rawData.isNotEmpty) {
    final bd = ByteData.sublistView(rawData);
    if (dataType == 1) {
      if (rawData.length < elemCount * 4) {
        throw const FormatException('Truncated ONNX float32 raw_data.');
      }
      for (var i = 0; i < elemCount; i++) {
        out[i] = bd.getFloat32(i * 4, Endian.little);
      }
    } else if (dataType == 7) {
      if (rawData.length < elemCount * 8) {
        throw const FormatException('Truncated ONNX int64 raw_data.');
      }
      for (var i = 0; i < elemCount; i++) {
        final lo = bd.getUint32(i * 8, Endian.little);
        final hi = bd.getInt32(i * 8 + 4, Endian.little);
        out[i] = (hi * 4294967296.0 + lo).toDouble();
      }
    } else if (dataType == 6) {
      if (rawData.length < elemCount * 4) {
        throw const FormatException('Truncated ONNX int32 raw_data.');
      }
      for (var i = 0; i < elemCount; i++) {
        out[i] = bd.getInt32(i * 4, Endian.little).toDouble();
      }
    } else if (dataType == 11) {
      if (rawData.length < elemCount * 8) {
        throw const FormatException('Truncated ONNX float64 raw_data.');
      }
      for (var i = 0; i < elemCount; i++) {
        out[i] = bd.getFloat64(i * 8, Endian.little);
      }
    } else {
      throw FormatException('Unsupported ONNX TensorProto dataType=$dataType');
    }
  } else if (floatData.isNotEmpty) {
    for (var i = 0; i < elemCount && i < floatData.length; i++) {
      out[i] = floatData[i];
    }
  } else if (int64Data.isNotEmpty) {
    for (var i = 0; i < elemCount && i < int64Data.length; i++) {
      out[i] = int64Data[i].toDouble();
    }
  } else if (int32Data.isNotEmpty) {
    for (var i = 0; i < elemCount && i < int32Data.length; i++) {
      out[i] = int32Data[i].toDouble();
    }
  }

  return (name, OnnxTensor(dims, out));
}
