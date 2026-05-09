import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../bridge/sia_bridge.dart';
import '../../services/auth_service.dart';
import 'welcome_screen.dart';

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
          if (_isConnecting) ...[
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              'Connecting to Sia...',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'A browser window will open for you to approve the app.\n'
              'Once approved, registration will complete automatically.',
              textAlign: TextAlign.center,
            ),
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
              onPressed: _goToWelcome,
              child: const Text('Continue'),
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
      final approvalUrl = await SiaBridge.requestConnection();

      // 2. Open the approval URL for the user to authorize.
      final uri = Uri.parse(approvalUrl);
      await launchUrl(uri, mode: LaunchMode.externalApplication);

      // 3. Complete registration — blocks until user approves, then registers.
      final appKeyHex = await SiaBridge.registerWithPhrase(_recoveryPhrase!);

      // 4. Persist only the App Key for future sessions.
      final auth = ref.read(authServiceProvider);
      await auth.storeAppKey(appKeyHex);

      // Keep the recovery phrase transient (never persisted by the app).
      _recoveryPhrase = null;
      _phraseController.clear();

      setState(() => _isConnecting = false);
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

  void _goToWelcome() {
    ref.invalidate(authStateProvider);
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (_) => false,
    );
  }
}
