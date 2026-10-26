import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// PC 版（Windows）かどうか。保存ダイアログを使うかの判定に使う
bool get usesSaveDialog => Platform.isWindows;

/// GPX ファイルを書き出す。
/// - スマホ: 一時ファイルに書いて共有シートを開く
/// - Windows: 「名前を付けて保存」ダイアログで選んだ場所に保存する
///
/// 戻り値: Windows で保存した場所。キャンセルしたとき・スマホのときは null
Future<String?> exportGpxFile({required String fileName, required String gpx, required String subject}) async {
  if (usesSaveDialog) {
    final location = await getSaveLocation(
      suggestedName: fileName,
      confirmButtonText: '保存',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'GPX ファイル', extensions: ['gpx']),
      ],
    );
    if (location == null) return null;
    var path = location.path;
    if (!path.toLowerCase().endsWith('.gpx')) path = '$path.gpx';
    await File(path).writeAsString(gpx);
    return path;
  }

  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsString(gpx);
  try {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/gpx+xml')],
        subject: subject,
      ),
    );
  } finally {
    // 走行記録を端末に残さない（共有先へ渡すファイルは share_plus が別に複製している）
    try {
      await file.delete();
    } catch (_) {}
  }
  return null;
}
