import 'package:material_ui/material_ui.dart';

import '../app.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/safety.dart';
import 'chat_screen.dart';

/// Открывает переписку и после возврата обновляет списки.
Future<void> openChat(BuildContext context, Match match) async {
  final state = AppScope.read(context);
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(match: match)));
  try {
    await state.loadMatches();
  } catch (_) {
    // Списки обновятся при следующем открытии вкладки.
  }
}

/// Общая обёртка вкладок: загрузка, ошибка, обновление жестом.
class _MatchesFrame extends StatelessWidget {
  const _MatchesFrame({required this.title, required this.builder});

  final String title;
  final Widget Function(AppState state) builder;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final Widget body;
    if (state.matches == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = RefreshIndicator(
        onRefresh: () => state.loadMatches().catchError((Object e) {
          if (context.mounted) showError(context, e);
        }),
        child: builder(state),
      );
    }
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Text(title, style: Theme.of(context).textTheme.headlineSmall),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _EmptyList extends StatelessWidget {
  const _EmptyList({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    // ListView, чтобы работало «потянуть для обновления».
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 80, 32, 32),
      children: [
        Icon(icon, size: 44, color: AppColors.accent),
        const SizedBox(height: 12),
        Text(title, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(text, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
      ],
    );
  }
}

/// «Совпадения»: взаимные интересы, где ещё никто не написал.
class MatchesTab extends StatelessWidget {
  const MatchesTab({super.key});

  @override
  Widget build(BuildContext context) {
    return _MatchesFrame(
      title: 'Совпадения',
      builder: (state) {
        final items = state.newMatches;
        if (items.isEmpty) {
          return _EmptyList(
            icon: Icons.favorite_border,
            title: state.chats.isEmpty ? 'Пока никого' : 'Новых совпадений нет',
            text: state.chats.isEmpty
                ? 'Отмечайте «Интересно» в ленте. Когда интерес взаимный, человек появится здесь.'
                : 'Все, с кем вы совпали, уже в «Чатах».',
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.78,
          ),
          itemCount: items.length,
          itemBuilder: (context, i) => _MatchCard(match: items[i]),
        );
      },
    );
  }
}

class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.match});

  final Match match;

  @override
  Widget build(BuildContext context) {
    final p = match.other;
    final g = goalInfo(match.goal);
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppColors.line),
      ),
      child: InkWell(
        key: Key('match-${match.matchId}'),
        borderRadius: BorderRadius.circular(20),
        onTap: () => openChat(context, match),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Avatar(name: p.name, goal: match.goal, size: 56),
              const SizedBox(height: 10),
              Text(
                '${p.name}, ${p.age}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const SizedBox(height: 6),
              Tag(goalShort[g.id] ?? g.label, color: g.color, background: g.tint),
              const Spacer(),
              Text(
                p.interests.take(3).join(', '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// «Чаты»: начатые переписки, свежие сверху.
class ChatsTab extends StatelessWidget {
  const ChatsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return _MatchesFrame(
      title: 'Чаты',
      builder: (state) {
        final items = state.chats;
        if (items.isEmpty) {
          return const _EmptyList(
            icon: Icons.chat_bubble_outline,
            title: 'Переписок пока нет',
            text: 'Напишите кому-нибудь из «Совпадений» — начните с общего интереса.',
          );
        }
        final me = state.me?.userId;
        return ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 84),
          itemBuilder: (context, i) {
            final m = items[i];
            final last = m.lastMessage!;
            return ListTile(
              key: Key('chat-${m.matchId}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              leading: Avatar(name: m.other.name, goal: m.goal, size: 52),
              title: Text(m.other.name, style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(
                '${last.sender == me ? 'Вы: ' : ''}${last.body}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: Text(shortTime(last.createdAt), style: Theme.of(context).textTheme.bodySmall),
              onTap: () => openChat(context, m),
            );
          },
        );
      },
    );
  }
}
