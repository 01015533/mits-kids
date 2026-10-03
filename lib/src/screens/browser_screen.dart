import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/download_service.dart';
import '../services/filter_script.dart';
import '../services/settings_repository.dart';
import '../services/parent_session.dart';
import '../services/url_policy.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({
    required this.downloader,
    required this.session,
    super.key,
  });
  final DownloadService downloader;
  final ParentSession session;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final settings = SettingsRepository();
  InAppWebViewController? controller;

  Future<void> inject() async {
    try {
      final web = controller;
      if (web == null ||
          !widget.session.unlocked ||
          !UrlPolicy.isAllowedNavigation(await web.getUrl())) {
        return;
      }
      final config = await settings.loadConfig();
      if (!mounted || !widget.session.unlocked) return;
      await web.evaluateJavascript(source: FilterScript.build(config));
    } catch (_) {
      if (mounted && widget.session.unlocked) {
        show('Browse filters could not be applied. Check Parent settings.');
      }
    }
  }

  Future<void> saveCurrent() async {
    final web = controller;
    if (web == null || widget.downloader.busy || !widget.session.unlocked) {
      return;
    }
    try {
      final token = widget.session.token;
      final url = (await web.getUrl())?.toString() ?? '';
      if (!mounted ||
          !widget.session.unlocked ||
          widget.session.token != token) {
        return;
      }
      if (!UrlPolicy.isDownloadableVideo(Uri.tryParse(url))) {
        show('Open a standard YouTube video before saving it.');
        return;
      }
      await widget.downloader.save(
        sourceUrl: url,
        rules: await settings.loadConfig(),
        approve: (metadata) async {
          if (!mounted || !widget.session.unlocked) return false;
          final token = widget.session.token;
          final approved = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              scrollable: true,
              title: const Text('Approve for your child?'),
              content: Text(
                '${metadata.title}\n${metadata.author}\n\nOnly approve videos you have reviewed. The saved video becomes available without a PIN.\n\nOnce approved, this save can finish after parent access locks or you switch apps, for up to 30 minutes. Progress and Cancel remain in Offline. Allow download notifications to follow or cancel it outside the app. Closing or restarting MITS stops the save. Parent controls still lock after five minutes.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Approve and save'),
                ),
              ],
            ),
          );
          return approved == true &&
              widget.session.unlocked &&
              widget.session.token == token;
        },
      );
    } catch (error) {
      // The AppShell keeps download outcomes visible when Browse is removed
      // on lock. Only failures before the job starts need a local message.
      if (mounted &&
          widget.session.unlocked &&
          widget.downloader.lastError == null) {
        show('Could not save this video: $error');
      }
    }
  }

  void show(String message) {
    if (!mounted || !widget.session.unlocked) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Material(
        color: const Color(0xFF0D1A2B),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              const Icon(Icons.shield_outlined, color: Color(0xFF58A6FF)),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Parent browsing',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Lock parent access',
                onPressed: widget.session.lock,
                icon: const Icon(Icons.lock_outline),
              ),
              IconButton(
                tooltip: 'Previous YouTube page',
                onPressed: () => controller?.goBack(),
                icon: const Icon(Icons.arrow_back),
              ),
              IconButton(
                tooltip: 'Reload YouTube page',
                onPressed: () => controller?.reload(),
                icon: const Icon(Icons.refresh),
              ),
              FilledButton.icon(
                onPressed: widget.downloader.busy ? null : saveCurrent,
                icon: const Icon(Icons.download),
                label: Text(
                  widget.downloader.busy ? 'Saving…' : 'Approve & save',
                ),
              ),
            ],
          ),
        ),
      ),
      Expanded(
        child: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri('https://m.youtube.com/')),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            javaScriptBridgeEnabled: false,
            allowFileAccess: false,
            allowContentAccess: false,
            supportMultipleWindows: false,
            javaScriptCanOpenWindowsAutomatically: false,
            useShouldOverrideUrlLoading: true,
            incognito: true,
            cacheEnabled: false,
            isInspectable: false,
            safeBrowsingEnabled: true,
            thirdPartyCookiesEnabled: false,
            allowFileAccessFromFileURLs: false,
            allowUniversalAccessFromFileURLs: false,
            mediaPlaybackRequiresUserGesture: true,
            mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
          ),
          onWebViewCreated: (value) => controller = value,
          onCreateWindow: (_, __) async => false,
          onShowFileChooser: (_, __) async =>
              ShowFileChooserResponse(handledByClient: true, filePaths: null),
          onPermissionRequest: (_, request) async => PermissionResponse(
            resources: request.resources,
            action: PermissionResponseAction.DENY,
          ),
          onGeolocationPermissionsShowPrompt: (_, origin) async =>
              GeolocationPermissionShowPromptResponse(
                origin: origin,
                allow: false,
                retain: false,
              ),
          onLoadStop: (_, __) => inject(),
          onUpdateVisitedHistory: (_, __, ___) => inject(),
          shouldOverrideUrlLoading: (_, action) async {
            final allowed =
                widget.session.unlocked &&
                UrlPolicy.isAllowedNavigation(action.request.url);
            if (!allowed) show('Only YouTube browsing is available here.');
            return allowed
                ? NavigationActionPolicy.ALLOW
                : NavigationActionPolicy.CANCEL;
          },
        ),
      ),
    ],
  );
}
