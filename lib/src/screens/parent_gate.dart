import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/parent_session.dart';

class ParentGate extends StatefulWidget {
  const ParentGate({required this.session, super.key});
  final ParentSession session;
  @override
  State<ParentGate> createState() => _ParentGateState();
}

class _ParentGateState extends State<ParentGate> {
  final pin = TextEditingController();
  final replacement = TextEditingController();
  final confirmation = TextEditingController();
  bool busy = false;
  String? error;

  Future<void> submit() async {
    if (busy) return;
    final setup = !widget.session.configured;
    final migrate = widget.session.legacy;
    final fresh = migrate ? replacement.text : pin.text;
    if ((setup || migrate) &&
        (!RegExp(r'^\d{6,12}$').hasMatch(fresh) ||
            fresh != confirmation.text)) {
      setState(() => error = 'Choose a 6–12 digit PIN and enter it twice.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.session.authenticate(
        pin.text,
        newPin: migrate ? fresh : null,
      );
    } on PlatformException catch (e) {
      if (mounted) setState(() => error = e.message ?? 'Unable to unlock.');
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Unlock was interrupted. Please try again.');
      }
    } finally {
      if (mounted) {
        pin.clear();
        replacement.clear();
        confirmation.clear();
        setState(() => busy = false);
      }
    }
  }

  @override
  void dispose() {
    pin.dispose();
    replacement.dispose();
    confirmation.dispose();
    super.dispose();
  }

  Widget field(TextEditingController controller, String label) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: TextField(
      controller: controller,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      maxLength: 12,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final setup = !widget.session.configured;
    final migrate = widget.session.legacy;
    return Scaffold(
      appBar: AppBar(title: Text(setup ? 'Parent setup' : 'Parent access')),
      body: Center(
        child: SingleChildScrollView(
          child: SizedBox(
            width: 440,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock_outline, size: 52),
                  const SizedBox(height: 16),
                  Text(
                    setup
                        ? 'A parent must finish setup before handing over this tablet. Choose a private PIN that your child does not know.'
                        : migrate
                        ? 'Enter your existing PIN, then choose a new 6–12 digit PIN to upgrade parent security.'
                        : 'Unlock to browse YouTube, approve downloads or change settings. Parent access locks when you leave the app and after five minutes.',
                  ),
                  field(pin, setup ? 'New parent PIN' : 'Parent PIN'),
                  if (migrate) field(replacement, 'New parent PIN'),
                  if (setup || migrate) field(confirmation, 'Confirm new PIN'),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  FilledButton(
                    onPressed: busy ? null : submit,
                    child: Text(
                      busy
                          ? 'Checking…'
                          : setup
                          ? 'Complete parent setup'
                          : 'Unlock',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
