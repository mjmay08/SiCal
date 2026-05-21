import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_custom_tabs/flutter_custom_tabs.dart' as custom_tabs;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../bridge/sia_bridge.dart';
import '../../services/auth_service.dart';
import 'calendar_screen.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  String? _recoveryPhrase;
  bool _phraseConfirmed = false;
  bool _isConnecting = false;
  bool _awaitingApproval = false;
  bool _approvalCallActive =
      false; // guard against concurrent waitForApproval calls
  String _connectingSubtitle = '';
  String? _pendingApprovalUrl;
  final _phraseController = TextEditingController();

  @override
  void dispose() {
    _pageController.dispose();
    _phraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: PageView(
          controller: _pageController,
          physics: const NeverScrollableScrollPhysics(),
          onPageChanged: (_) {},
          children: [
            _buildWelcomePage(),
            _buildChoicePage(),
            _buildNewPhrasePage(),
            _buildRestorePage(),
            _buildConnectingPage(),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcomePage() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.calendar_month,
            size: 96,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 24),
          Text('SiCal', style: Theme.of(context).textTheme.headlineLarge),
          const SizedBox(height: 16),
          Text(
            'Your calendar, encrypted and stored on the decentralized Sia network. No accounts. No servers. Just your data.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 48),
          FilledButton(
            onPressed: () => _goToPage(1),
            child: const Text('Get Started'),
          ),
        ],
      ),
    );
  }

  Widget _buildChoicePage() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Set Up Your Calendar',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: _generatePhrase,
            icon: const Icon(Icons.add),
            label: const Text('Create New Calendar'),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => _goToPage(3),
            icon: const Icon(Icons.restore),
            label: const Text('Restore from Recovery Phrase'),
          ),
        ],
      ),
    );
  }

  Widget _buildNewPhrasePage() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.key, size: 48, color: Theme.of(context).colorScheme.error),
          const SizedBox(height: 16),
          Text(
            'Your Recovery Phrase',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Write this down and store it safely. If you lose it, your calendar data cannot be recovered.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              _recoveryPhrase ?? '',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontFamily: 'monospace',
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () {
              if (_recoveryPhrase != null) {
                Clipboard.setData(ClipboardData(text: _recoveryPhrase!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard')),
                );
              }
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
          const SizedBox(height: 24),
          CheckboxListTile(
            value: _phraseConfirmed,
            onChanged: (v) => setState(() => _phraseConfirmed = v ?? false),
            title: const Text("I've written down my recovery phrase"),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _phraseConfirmed ? _startConnection : null,
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Widget _buildRestorePage() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Enter Recovery Phrase',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _phraseController,
            maxLines: 3,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Enter your 12-word recovery phrase...',
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () {
              final phrase = _phraseController.text.trim();
              if (phrase.split(' ').length >= 12) {
                _recoveryPhrase = phrase;
                _startConnection();
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please enter a valid 12-word phrase'),
                  ),
                );
              }
            },
            child: const Text('Restore'),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: () => _goToPage(1), child: const Text('Back')),
        ],
      ),
    );
  }

  Widget _buildConnectingPage() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_awaitingApproval) ...[
            Icon(
              Icons.open_in_browser,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              'Approve in Browser',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'A secure browser tab opened for you to approve the connection.\n'
              'Once you have approved, come back here and tap Continue.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _completeRegistration,
              icon: const Icon(Icons.check),
              label: const Text("I've Approved — Continue"),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pendingApprovalUrl == null
                  ? null
                  : () => _openApprovalPage(_pendingApprovalUrl!),
              icon: const Icon(Icons.open_in_browser),
              label: const Text('Reopen Approval Page'),
            ),
          ] else if (_isConnecting) ...[
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              'Connecting to Sia...',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(_connectingSubtitle, textAlign: TextAlign.center),
            if (_connectingSubtitle.contains('Checking')) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => setState(() {
                  _isConnecting = false;
                  _awaitingApproval = true;
                }),
                child: const Text("Not approved yet — go back"),
              ),
            ],
          ] else ...[
            Icon(
              Icons.check_circle,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              'Connected!',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _goToCalendar,
              child: const Text('Open Calendar'),
            ),
          ],
        ],
      ),
    );
  }

  void _goToPage(int page) {
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _generatePhrase() {
    setState(() {
      _recoveryPhrase = SiaBridge.generateRecoveryPhrase();
    });
    _goToPage(2);
  }

  Future<void> _startConnection() async {
    _goToPage(4);
    setState(() => _isConnecting = true);

    try {
      // 1. Request app connection — returns an approval URL.
      setState(
        () => _connectingSubtitle =
            'Opening a secure browser tab for approval...',
      );
      final approvalUrl = await SiaBridge.requestConnection();
      _pendingApprovalUrl = approvalUrl;

      // 2. Open the approval URL in a Custom Tab / SFSafariViewController.
      //    This keeps the user "in-app".
      await _openApprovalPage(approvalUrl);

      // 3. Tab has been closed — show "I've Approved" button so the user can
      //    explicitly trigger the approval poll while the app is foregrounded.
      //    waitForApproval() must NOT be called while in the background.
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _awaitingApproval = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isConnecting = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Connection failed: $e')));
        _goToPage(1);
      }
    }
  }

  Future<void> _completeRegistration() async {
    if (_approvalCallActive) {
      dev.log(
        '[Onboarding] _completeRegistration: skipped — call already in progress',
        name: 'Onboarding',
      );
      return;
    }
    _approvalCallActive = true;
    dev.log('[Onboarding] _completeRegistration: started', name: 'Onboarding');

    setState(() {
      _awaitingApproval = false;
      _isConnecting = true;
      _connectingSubtitle = 'Checking approval status...';
    });

    try {
      // Poll the approval status — app is foregrounded, network is available.
      dev.log('[Onboarding] calling waitForApproval()', name: 'Onboarding');
      await SiaBridge.waitForApproval();
      dev.log('[Onboarding] waitForApproval() succeeded', name: 'Onboarding');

      final appKeyHex = await SiaBridge.registerWithPhrase(_recoveryPhrase!);
      dev.log(
        '[Onboarding] registerWithPhrase() succeeded',
        name: 'Onboarding',
      );

      // Registration is complete — SDK is live. Clear sensitive data.
      _recoveryPhrase = null;
      _phraseController.clear();
      // NOTE: keep _approvalCallActive = true until the UI is fully updated
      // below so that a stray tap of "I've Approved" can't start a new call.

      // Persist the key. A failure here is non-fatal for the current session
      // (SDK is already connected) but the user will need to reconnect next
      // launch if we can't save it.
      try {
        dev.log('[Onboarding] calling storeAppKey()', name: 'Onboarding');
        final auth = ref.read(authServiceProvider);
        await auth.storeAppKey(appKeyHex);
        dev.log('[Onboarding] storeAppKey() succeeded', name: 'Onboarding');
      } catch (storeErr, st) {
        dev.log(
          '[Onboarding] storeAppKey() FAILED: $storeErr',
          name: 'Onboarding',
          error: storeErr,
          stackTrace: st,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Connected, but your key could not be saved. '
                'You may need to reconnect after restarting the app.',
              ),
              duration: Duration(seconds: 6),
            ),
          );
        }
      }

      // Update UI — clear both flags so we land on the "Connected!" view.
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _awaitingApproval = false;
        });
      }
      _approvalCallActive = false;
    } catch (e, st) {
      dev.log(
        '[Onboarding] _completeRegistration failed: $e',
        name: 'Onboarding',
        error: e,
        stackTrace: st,
      );
      _approvalCallActive = false;
      if (mounted) {
        // The Rust state was consumed by waitForApproval/registerWithPhrase —
        // the user cannot retry the approval button. Navigate back to the
        // choice page so they can restart from request_connection().
        setState(() {
          _isConnecting = false;
          _awaitingApproval = false;
          _pendingApprovalUrl = null;
        });
        _goToPage(1);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_approvalErrorMessage(e))));
      }
    }
  }

  /// Returns a user-friendly message for errors thrown by waitForApproval().
  String _approvalErrorMessage(Object e) {
    final raw = e.toString();
    if (raw.contains('wait_for_approval')) {
      return 'Approval was not confirmed. Please tap Connect and try again.';
    }
    if (raw.contains('no pending onboarding') ||
        raw.contains('not yet approved')) {
      return 'Something went wrong. Please tap Connect and try again.';
    }
    return 'Registration failed. Please tap Connect and try again.';
  }

  Future<void> _openApprovalPage(String approvalUrl) async {
    final uri = Uri.parse(approvalUrl);
    try {
      await custom_tabs.launchUrl(
        uri,
        customTabsOptions: const custom_tabs.CustomTabsOptions(
          showTitle: true,
          shareState: custom_tabs.CustomTabsShareState.off,
          urlBarHidingEnabled: true,
        ),
        safariVCOptions: const custom_tabs.SafariViewControllerOptions(
          barCollapsingEnabled: true,
          entersReaderIfAvailable: false,
        ),
      );
    } catch (_) {
      // Fallback if Custom Tabs / SFSafariViewController is unavailable.
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _goToCalendar() {
    ref.invalidate(authStateProvider);
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const CalendarScreen()),
      (_) => false,
    );
  }
}
