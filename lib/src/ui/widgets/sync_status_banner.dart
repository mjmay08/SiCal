import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ---------------------------------------------------------------------------
// Sync progress state
// ---------------------------------------------------------------------------

enum SyncPhase { idle, pulling, uploading, updatingMetadata, cleaning, done }

class SyncProgress {
  final SyncPhase phase;
  final String message;
  final int current;
  final int total;

  const SyncProgress({
    this.phase = SyncPhase.idle,
    this.message = '',
    this.current = 0,
    this.total = 0,
  });

  bool get isActive => phase != SyncPhase.idle && phase != SyncPhase.done;

  double? get progress => total > 0 ? current / total : null;

  SyncProgress copyWith({
    SyncPhase? phase,
    String? message,
    int? current,
    int? total,
  }) => SyncProgress(
    phase: phase ?? this.phase,
    message: message ?? this.message,
    current: current ?? this.current,
    total: total ?? this.total,
  );
}

final syncProgressProvider =
    NotifierProvider<SyncProgressNotifier, SyncProgress>(
      SyncProgressNotifier.new,
    );

class SyncProgressNotifier extends Notifier<SyncProgress> {
  @override
  SyncProgress build() => const SyncProgress();

  void update({SyncPhase? phase, String? message, int? current, int? total}) {
    state = state.copyWith(
      phase: phase,
      message: message,
      current: current,
      total: total,
    );
  }

  void reset() => state = const SyncProgress();
}

// Keep the old provider as a simple derived bool for any code still using it.
final isSyncingProvider = Provider<bool>((ref) {
  return ref.watch(syncProgressProvider).isActive;
});

// ---------------------------------------------------------------------------
// Banner widget
// ---------------------------------------------------------------------------

/// A banner that shows sync status below the app bar.
class SyncStatusBanner extends ConsumerWidget {
  const SyncStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(syncProgressProvider);
    if (!progress.isActive) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      color: colors.primaryContainer,
      child: Row(
        children: [
          if (progress.progress != null) ...[
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                value: progress.progress,
                strokeWidth: 2,
                color: colors.onPrimaryContainer,
              ),
            ),
          ] else ...[
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.onPrimaryContainer,
              ),
            ),
          ],
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              progress.message.isNotEmpty
                  ? progress.message
                  : 'Syncing with Sia...',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.onPrimaryContainer,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (progress.total > 0)
            Text(
              '${progress.current}/${progress.total}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.onPrimaryContainer.withValues(alpha: 0.7),
              ),
            ),
        ],
      ),
    );
  }
}
