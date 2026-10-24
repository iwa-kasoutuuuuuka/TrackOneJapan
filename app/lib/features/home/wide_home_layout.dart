import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

import 'device_card.dart';
import 'device_list_view.dart';
import 'map_view.dart';

/// 横に広い画面（PC 版・タブレット横向き）とみなす幅
const double kWideLayoutMinWidth = 900;

/// 画面が広いかどうか
bool isWideLayout(BuildContext context) => MediaQuery.sizeOf(context).width >= kWideLayoutMinWidth;

/// 広い画面用のホーム: 左に端末一覧、右に地図と端末カードを並べる
/// （狭い画面の「地図／一覧」切り替えの代わり。部品は同じものを使う）
class WideHomeLayout extends StatelessWidget {
  const WideHomeLayout({super.key});

  static const double _listWidth = 360;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 一覧で端末を選ぶと、右の地図がその端末へ移動する
          SizedBox(
            width: _listWidth,
            // マウスでも一覧を下に引っ張って更新できるようにする（PC 版）
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: {...ScrollConfiguration.of(context).dragDevices, PointerDeviceKind.mouse},
              ),
              child: DeviceListView(onOpenOnMap: () {}),
            ),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          const Expanded(child: Column(children: [Expanded(child: MapView()), DeviceCard()])),
        ],
      );
}
