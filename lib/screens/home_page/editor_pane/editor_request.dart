import 'package:apidash_design_system/apidash_design_system.dart';
import 'package:apidash_core/apidash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:apidash/consts.dart';
import 'package:apidash/providers/providers.dart';
import 'details_card/details_card.dart';
import 'details_card/request_pane/request_pane.dart';
import 'request_editor_top_bar.dart';
import 'url_card.dart';

class RequestEditor extends ConsumerWidget {
  const RequestEditor({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final apiType = ref.watch(
        selectedRequestModelProvider.select((value) => value?.apiType));
    final isHttp = apiType == APIType.rest ||
        apiType == APIType.graphql ||
        apiType == APIType.ai;

    return context.isMediumWindow
        ? const Padding(
            padding: kPb10,
            child: Column(
              children: [
                kVSpacer20,
                Expanded(
                  child: EditRequestPane(
                    showViewCodeButton: false,
                  ),
                ),
              ],
            ),
          )
        : Padding(
            padding: kIsMacOS ? kPt28o8 : kP8,
            child: Column(
              children: [
                const RequestEditorTopBar(),
                if (isHttp) const EditorPaneRequestURLCard(),
                if (isHttp) kVSpacer10,
                const Expanded(
                  child: EditorPaneRequestDetailsCard(),
                ),
              ],
            ),
          );
  }
}
