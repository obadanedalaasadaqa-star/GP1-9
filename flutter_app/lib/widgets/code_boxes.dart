import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/design.dart';

/// The 6-digit code slip: a white receipt slip with "YOUR CODE" and six boxes.
/// One hidden text field drives the boxes (digits only, iOS one-time-code
/// autofill). Used by the email-code / 2FA screen and the password reset.
/// [hasError]: the boxes get the danger border until the parent clears it.
class CodeBoxes extends StatelessWidget {
  static const length = 6;

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool hasError;
  final ValueChanged<String>? onChanged;

  const CodeBoxes({
    super.key,
    required this.controller,
    required this.focusNode,
    this.hasError = false,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    const ink = AppColors.ink;

    return Padding(
      // Room for the hard shadow, so it isn't clipped.
      padding: const EdgeInsets.only(right: 6),
      child: Transform.rotate(
        angle: 0.012,
        child: DecoratedBox(
          decoration: BoxDecoration(boxShadow: [
            BoxShadow(color: nx.dark ? AppColors.lime : ink, offset: const Offset(5, 6)),
          ]),
          child: Column(
            children: [
              const ReceiptEdge(color: Colors.white, up: true),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('YOUR CODE', style: NxType.label(AppColors.textMutedLight)),
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: () => focusNode.requestFocus(),
                      child: Stack(
                        children: [
                          // Invisible but still in the accessibility tree,
                          // so VoiceOver can reach the code field.
                          Opacity(
                            opacity: 0,
                            alwaysIncludeSemantics: true,
                            child: TextField(
                              controller: controller,
                              focusNode: focusNode,
                              keyboardType: TextInputType.number,
                              autofillHints: const [AutofillHints.oneTimeCode],
                              maxLength: length,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              onChanged: onChanged,
                            ),
                          ),
                          Semantics(
                            label: '6-digit code',
                            textField: true,
                            child: ExcludeSemantics(
                              child: ListenableBuilder(
                                listenable: Listenable.merge([controller, focusNode]),
                                builder: (context, _) => Row(
                                  children: List.generate(length, (i) {
                                    final text = controller.text;
                                    final filled = i < text.length;
                                    final active = focusNode.hasFocus && i == text.length;
                                    return Expanded(
                                      child: Container(
                                        height: 58,
                                        margin: EdgeInsets.only(right: i < length - 1 ? 7 : 0),
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: filled ? AppColors.lime : Colors.white,
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(
                                            width: active ? 3 : 2,
                                            color: hasError
                                                ? AppColors.danger
                                                : active ? AppColors.cobalt : ink),
                                        ),
                                        child: Text(filled ? text[i] : '',
                                          style: NxType.mono(24, color: ink, weight: FontWeight.w500)),
                                      ),
                                    );
                                  }),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const ReceiptEdge(color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}
