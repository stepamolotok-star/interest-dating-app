import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../api/api.dart';
import '../app.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/safety.dart';

/// Переписка с человеком, с которым интерес взаимный.
/// Новые сообщения пока подтягиваем опросом раз в несколько секунд (см. docs/decisions.md).
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.match});

  final Match match;

  static const pollEvery = Duration(seconds: 4);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final Api _api = AppScope.read(context).api;
  late final String _me = AppScope.read(context).me?.userId ?? '';
  final _input = TextEditingController();

  /// От новых к старым — так удобно для перевёрнутого списка.
  List<Message> _items = [];
  bool _loaded = false;
  bool _loadingOlder = false;
  bool _noMore = false;
  bool _closed = false;
  bool _sending = false;
  String? _sendError;
  Timer? _poll;

  Match get m => widget.match;

  @override
  void initState() {
    super.initState();
    // Ошибку сбрасываем только когда меняется сам текст, а не курсор или фокус.
    var lastText = '';
    _input.addListener(() {
      if (_input.text == lastText) return;
      lastText = _input.text;
      setState(() => _sendError = null);
    });
    Future.microtask(_refresh);
    _poll = Timer.periodic(ChatScreen.pollEvery, (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    super.dispose();
  }

  void _merge(List<Message> fresh) {
    final byId = {for (final x in _items) x.id: x, for (final x in fresh) x.id: x};
    _items = byId.values.toList()..sort((a, b) => b.id.compareTo(a.id));
  }

  Future<void> _refresh() async {
    if (_closed) return;
    try {
      final fresh = await _api.messages(m.matchId);
      if (!mounted) return;
      setState(() {
        _merge(fresh);
        if (!_loaded && fresh.length < 50) _noMore = true;
        _loaded = true;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.status == 404) {
        _poll?.cancel();
        setState(() => _closed = true);
      } else if (!_loaded) {
        showError(context, e);
      }
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || _noMore || _items.isEmpty) return;
    _loadingOlder = true;
    try {
      final older = await _api.messages(m.matchId, before: _items.last.id);
      if (!mounted) return;
      setState(() {
        _merge(older);
        if (older.length < 50) _noMore = true;
      });
    } catch (_) {
      // Попробуем снова при следующей прокрутке.
    } finally {
      _loadingOlder = false;
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final sent = await _api.send(m.matchId, text);
      if (!mounted) return;
      _input.clear();
      setState(() => _merge([sent]));
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.status == 404) {
        setState(() => _closed = true);
      } else {
        setState(() => _sendError = e.message[0].toUpperCase() + e.message.substring(1));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _menu(String action) async {
    final state = AppScope.read(context);
    final nav = Navigator.of(context);
    switch (action) {
      case 'profile':
        await showPersonSheet(context, m);
      case 'report':
        final blocked = await showReportSheet(context, m.other);
        if (blocked) {
          state.forgetMatch(m.matchId);
          nav.pop();
        }
      case 'block':
        if (!await confirm(
          context,
          title: 'Заблокировать ${m.other.name}?',
          text: 'Переписка закроется, и вы больше не увидите друг друга ни в ленте, ни в «Рядом».',
          ok: 'Заблокировать',
        )) {
          return;
        }
        await _guard(() => _api.block(m.other.userId));
        state.forgetMatch(m.matchId);
        nav.pop();
      case 'end':
        if (!await confirm(
          context,
          title: 'Завершить общение?',
          text: 'Переписка закроется у вас обоих. ${m.other.name} не узнает причину.',
          ok: 'Завершить',
        )) {
          return;
        }
        await _guard(() => _api.endMatch(m.matchId));
        state.forgetMatch(m.matchId);
        nav.pop();
    }
  }

  Future<void> _guard(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      if (mounted) showError(context, e);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = goalInfo(m.goal);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => showPersonSheet(context, m),
          child: Row(
            children: [
              Avatar(name: m.other.name, goal: m.goal, size: 38),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${m.other.name}, ${m.other.age}', overflow: TextOverflow.ellipsis),
                    Text(
                      goalShort[g.id] ?? g.label,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: g.color),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            key: const Key('chat-menu'),
            onSelected: (a) => _menu(a).catchError((_) {}),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'profile', child: Text('Анкета')),
              PopupMenuItem(value: 'report', child: Text('Пожаловаться')),
              PopupMenuItem(value: 'block', child: Text('Заблокировать')),
              PopupMenuItem(value: 'end', child: Text('Завершить общение')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _list()),
            if (_closed)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                color: AppColors.surface,
                child: Text(
                  'Переписка закрыта',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              _composer(),
          ],
        ),
      ),
    );
  }

  Widget _list() {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    final hasText = _items.any((x) => !x.isSystem);
    if (!hasText) return _Hello(match: m, onUse: (text) => _input.text = text);
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      itemCount: _items.length,
      itemBuilder: (context, i) {
        if (i == _items.length - 1) _loadOlder();
        final msg = _items[i];
        final older = i + 1 < _items.length ? _items[i + 1] : null;
        final newDay = older == null || !_sameDay(older.createdAt, msg.createdAt);
        return Column(
          children: [
            if (newDay) _DayLabel(msg.createdAt),
            if (msg.isSystem) _SystemLine(msg.body) else _Bubble(msg: msg, mine: msg.sender == _me),
          ],
        );
      },
    );
  }

  Widget _composer() {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_sendError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(_sendError!, style: const TextStyle(color: AppColors.error, fontSize: 13)),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('message'),
                  controller: _input,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: 2000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'Сообщение',
                    counterText: '',
                    filled: true,
                    fillColor: AppColors.bg,
                    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filled(
                key: const Key('send'),
                style: IconButton.styleFrom(backgroundColor: goalInfo(m.goal).color),
                onPressed: _input.text.trim().isEmpty || _sending ? null : _send,
                icon: const Icon(Icons.arrow_upward),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

const _months = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];

String dayLabel(DateTime t, {DateTime? now}) {
  final today = now ?? DateTime.now();
  if (_sameDay(t, today)) return 'Сегодня';
  if (_sameDay(t, today.subtract(const Duration(days: 1)))) return 'Вчера';
  return '${t.day} ${_months[t.month - 1]}${t.year == today.year ? '' : ' ${t.year}'}';
}

/// Короткое время для списка чатов: «14:05», «Вчера», «3 ноября».
String shortTime(DateTime t, {DateTime? now}) {
  final today = now ?? DateTime.now();
  return _sameDay(t, today) ? _hhmm(t) : dayLabel(t, now: today);
}

class _DayLabel extends StatelessWidget {
  const _DayLabel(this.time);

  final DateTime time;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Text(dayLabel(time), style: Theme.of(context).textTheme.bodySmall),
  );
}

class _SystemLine extends StatelessWidget {
  const _SystemLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
    child: Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.msg, required this.mine});

  final Message msg;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final bg = mine ? AppColors.accent : AppColors.surface;
    final fg = mine ? Colors.white : AppColors.ink;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 7),
          decoration: BoxDecoration(
            color: bg,
            border: mine ? null : Border.all(color: AppColors.line),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(mine ? 18 : 4),
              bottomRight: Radius.circular(mine ? 4 : 18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SelectableText(msg.body, style: TextStyle(color: fg, fontSize: 15, height: 1.35)),
              const SizedBox(height: 2),
              Text(
                _hhmm(msg.createdAt),
                style: TextStyle(color: mine ? Colors.white70 : AppColors.muted, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Пустая переписка: с чем совпали и подсказка для первого сообщения.
class _Hello extends StatelessWidget {
  const _Hello({required this.match, required this.onUse});

  final Match match;
  final ValueChanged<String> onUse;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final g = goalInfo(match.goal);
    final topic = match.other.interests.isEmpty ? null : match.other.interests.first;
    final hint = topic == null
        ? 'Привет! Расскажи, чем ты сейчас увлекаешься?'
        : 'Привет! У нас общий интерес — «$topic». С чего у тебя всё началось?';
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 24),
        Center(
          child: Avatar(name: match.other.name, goal: match.goal, size: 80),
        ),
        const SizedBox(height: 14),
        Text('${match.other.name}, ${match.other.age}', style: t.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Text(
          'Интерес взаимный, цель — «${g.label}». Начните с общего увлечения: так проще, '
          'чем «привет, как дела».',
          style: t.bodySmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        Material(
          color: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.line),
          ),
          child: InkWell(
            key: const Key('use-hint'),
            borderRadius: BorderRadius.circular(16),
            onTap: () => onUse(hint),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(child: Text(hint, style: t.bodyLarge)),
                  const SizedBox(width: 8),
                  Icon(Icons.edit_outlined, size: 18, color: g.color),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.shield_outlined, size: 16, color: AppColors.muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'В первом сообщении нельзя ссылки и контакты — это защищает от мошенников. '
                'Встречайтесь в людных местах и не переводите деньги незнакомцам.',
                style: t.bodySmall,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
