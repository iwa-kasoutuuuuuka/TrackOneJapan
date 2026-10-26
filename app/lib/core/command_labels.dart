import 'package:flutter/material.dart';

/// コマンドに必要な入力
enum CommandParam { none, text, seconds, sos }

/// Traccar のコマンドの日本語表示
class CommandInfo {
  const CommandInfo(this.label, this.description, this.icon, {this.param = CommandParam.none, this.danger = false});
  final String label;
  final String description;
  final IconData icon;
  final CommandParam param;

  /// 走行中に使うと危険・元に戻せないもの（2 回確認する）
  final bool danger;
}

const _labels = <String, CommandInfo>{
  'custom': CommandInfo('任意のコマンド', '発信機の説明書にあるコマンドを、文字で直接送ります（例：STATUS#、WHERE#）', Icons.terminal, param: CommandParam.text),
  'engineStop': CommandInfo('エンジン停止', '燃料・電源をカットしてエンジンを止めます。走行中に使うと大変危険です', Icons.block, danger: true),
  'engineResume': CommandInfo('エンジン再開', 'エンジン停止を解除します', Icons.play_circle_outline),
  'positionSingle': CommandInfo('今すぐ位置を送る', '発信機に、今の位置を 1 回送らせます', Icons.my_location),
  'positionPeriodic': CommandInfo('位置の送信間隔を変える', '何秒ごとに位置を送るかを変えます（短いほど電池が減ります）', Icons.timer_outlined, param: CommandParam.seconds),
  'positionStop': CommandInfo('位置の定期送信を止める', '位置を定期的に送るのをやめさせます', Icons.pause_circle_outline),
  'alarmArm': CommandInfo('警戒モード ON', '振動・移動の警報を有効にします', Icons.shield_outlined),
  'alarmDisarm': CommandInfo('警戒モード OFF', '振動・移動の警報を無効にします', Icons.remove_moderator_outlined),
  'alarmDismiss': CommandInfo('警報を止める', '鳴っている警報を止めます', Icons.notifications_off_outlined),
  'rebootDevice': CommandInfo('再起動', '発信機を再起動します', Icons.restart_alt),
  'powerOff': CommandInfo('電源オフ', '発信機の電源を切ります。現地で操作するまで位置が届かなくなります', Icons.power_settings_new, danger: true),
  'factoryReset': CommandInfo('工場出荷状態に戻す', 'すべての設定が消えます。サーバーの接続先も初期値に戻るため、届かなくなることがあります', Icons.settings_backup_restore, danger: true),
  'deviceIdentification': CommandInfo('端末情報の問い合わせ', '機種・ファームウェアなどを問い合わせます', Icons.info_outline),
  'requestPhoto': CommandInfo('写真を撮る', 'カメラ付きの発信機で写真を撮らせます', Icons.photo_camera_outlined),
  'sosNumber': CommandInfo('SOS 番号の設定', 'SOS ボタンを押したときの連絡先を設定します', Icons.contact_phone_outlined, param: CommandParam.sos),
  'setTimezone': CommandInfo('タイムゾーンの設定', '発信機の時刻を日本時間（GMT+9）に合わせます', Icons.schedule),
  'silenceTime': CommandInfo('サイレント時間の設定', '指定した時間帯は音を鳴らさないようにします', Icons.volume_off_outlined),
  'message': CommandInfo('メッセージを送る', '画面付きの発信機に文字を表示します', Icons.message_outlined, param: CommandParam.text),
};

/// 一覧にない種類は、何が起きるかわからないので危険なものとして扱う（2 回確認・保留しない）
CommandInfo describeCommand(String type) =>
    _labels[type] ?? CommandInfo(type, 'この種類のコマンドの内容はアプリではわかりません。何が起きるか確認してから送ってください', Icons.tune, danger: true);

/// 「任意のコマンド」の文面が、エンジン停止・電源オフ・初期化などに見えるか（GT06 系の代表的な文面）
bool looksDangerousCustom(String text) =>
    RegExp(r'RELAY|DYD|CUT|STOPENGINE|POWEROFF|POWER,?OFF|FACTORY|FORMAT', caseSensitive: false).hasMatch(text);

/// 危険な操作として扱うか（任意のコマンドは文面で判断）
bool isDangerousCommand(String type, {String? text}) =>
    describeCommand(type).danger || (type == 'custom' && looksDangerousCustom(text ?? ''));

/// 一覧に出す順番（よく使うもの・安全なものを先に、危険なものは最後）
int commandOrder(String type) {
  const order = ['positionSingle', 'custom', 'positionPeriodic', 'engineResume', 'alarmArm', 'alarmDisarm', 'rebootDevice'];
  final i = order.indexOf(type);
  if (i >= 0) return i;
  return describeCommand(type).danger ? 1000 : 500;
}

/// 送るときの属性を作る
Map<String, dynamic> commandAttributes(String type, {String? text, int? seconds, String? sosPhone}) => switch (type) {
      'custom' => {'data': text ?? ''},
      'message' => {'message': text ?? ''},
      'positionPeriodic' => {'frequency': seconds ?? 60},
      'sosNumber' => {'index': 1, 'phone': sosPhone ?? ''},
      'setTimezone' => {'timezone': 'GMT+9'},
      _ => <String, dynamic>{},
    };
