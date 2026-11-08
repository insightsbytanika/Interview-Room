import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/api_client.dart';
import '../core/session.dart';

// Status words we treat as "live" / "past". Change these to match your backend.
const _liveStatuses = {'live', 'active', 'in_progress', 'ongoing'};
const _pastStatuses = {'ended', 'completed', 'finished', 'closed', 'cancelled'};

const _amber = Color(0xFFF5B729);
const _green = Color(0xFF2ECC71);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.api, required this.session});
  final ApiClient api;
  final Session session;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<List<dynamic>> _meetings = widget.api.listMeetings();
  int _tab = 0; // 0 = Upcoming, 1 = Past, 2 = Favourites
  String _query = '';
  // TODO: favourites are only remembered until the page reloads.
  // Save them in the backend (is_favourite) in a later step.
  final Set<String> _favs = {};

  void _reload() => setState(() => _meetings = widget.api.listMeetings());

  Future<bool> _create(String title, String problem, bool console) async {
    try {
      await widget.api.createMeeting(
        title: title,
        problem: problem,
        console: console,
      );
      _reload();
      return true;
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
      return false;
    }
  }

  // ---------- small helpers ----------

  bool _isLive(Map<String, dynamic> m) =>
      _liveStatuses.contains('${m['status']}'.toLowerCase());
  bool _isPast(Map<String, dynamic> m) =>
      _pastStatuses.contains('${m['status']}'.toLowerCase());
  bool _isFav(Map<String, dynamic> m) =>
      _favs.contains(m['code']) || m['is_favourite'] == true;
  DateTime? _when(Map<String, dynamic> m) =>
      DateTime.tryParse('${m['scheduled_at'] ?? ''}')?.toLocal();

  String _joinLink(String code) {
    final base = Uri.base;
    final origin = base.hasAuthority
        ? '${base.scheme}://${base.authority}'
        : 'http://localhost:5000';
    return '$origin/join/$code';
  }

  String _fmt(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final t =
        '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour >= 12 ? 'PM' : 'AM'}';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
    if (diff == 0) return 'Today, $t';
    if (diff == 1) return 'Tomorrow, $t';
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}, $t';
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }

  List<Map<String, dynamic>> _visible(List<Map<String, dynamic>> all) {
    final q = _query.toLowerCase();
    return all.where((m) {
      final text = '${m['candidate_name'] ?? ''} ${m['title'] ?? ''}'
          .toLowerCase();
      if (q.isNotEmpty && !text.contains(q)) return false;
      return switch (_tab) {
        0 => !_isPast(m),
        1 => _isPast(m),
        _ => _isFav(m),
      };
    }).toList();
  }

  // ---------- layout ----------

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 1000;
        if (wide) {
          return Scaffold(
            body: Row(
              children: [
                _sidebar(context),
                Expanded(child: _main(context, wide: true)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 24, 24, 24),
                  child: SizedBox(
                    width: 340,
                    child: SingleChildScrollView(
                      child: _NewInterviewForm(onCreate: _create),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(title: const Text('Interviews')),
          drawer: Drawer(
            child: SafeArea(child: _sidebar(context, drawer: true)),
          ),
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.add),
            label: const Text('New interview'),
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (sheet) => Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(sheet).viewInsets.bottom,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _NewInterviewForm(
                    onCreate: (t, p, cns) async {
                      final ok = await _create(t, p, cns);
                      if (ok && sheet.mounted) Navigator.pop(sheet);
                      return ok;
                    },
                  ),
                ),
              ),
            ),
          ),
          body: _main(context, wide: false),
        );
      },
    );
  }

  Widget _sidebar(BuildContext context, {bool drawer = false}) {
    final cs = Theme.of(context).colorScheme;

    void go(int tab) {
      setState(() => _tab = tab);
      if (drawer) Navigator.pop(context);
    }

    return Container(
      width: 240,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: cs.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: cs.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.videocam_outlined,
                  size: 18,
                  color: cs.onPrimary,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'Interview Room',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _nav(
            context,
            Icons.calendar_today_outlined,
            'Interviews',
            _tab == 0,
            () => go(0),
          ),
          _nav(
            context,
            Icons.star_border,
            'Favourites',
            _tab == 2,
            () => go(2),
          ),
          _nav(
            context,
            Icons.history,
            'Past interviews',
            _tab == 1,
            () => go(1),
          ),
          _nav(context, Icons.mail_outline, 'Email settings', false, () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Email settings are coming soon')),
            );
          }),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: cs.outlineVariant),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: cs.primaryContainer,
                  child: Icon(Icons.person, size: 18, color: cs.primary),
                ),
                const SizedBox(width: 8),
                // TODO: show the real name from session once we know its field.
                const Expanded(
                  child: Text(
                    'Interviewer',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Toggle theme',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.brightness_6_outlined),
                  onPressed: () => widget.session.toggleTheme(context),
                ),
                IconButton(
                  tooltip: 'Sign out',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.logout),
                  onPressed: () async {
                    await widget.session.logout();
                    if (context.mounted) {
                      Navigator.of(context).pushReplacementNamed('/');
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _nav(
    BuildContext context,
    IconData icon,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? cs.surfaceContainerHighest : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected ? cs.onSurface : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: selected ? cs.onSurface : cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _main(BuildContext context, {required bool wide}) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<List<dynamic>>(
      future: _meetings,
      builder: (context, snap) {
        final loading = snap.connectionState != ConnectionState.done;
        final all = (!loading && !snap.hasError)
            ? snap.data!.cast<Map<String, dynamic>>()
            : <Map<String, dynamic>>[];
        final upcoming = all.where((m) => !_isPast(m)).length;
        final items = _visible(all);

        Widget list;
        if (loading) {
          list = const Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: CircularProgressIndicator()),
          );
        } else if (snap.hasError) {
          list = Padding(
            padding: const EdgeInsets.all(24),
            child: Text('${snap.error}'),
          );
        } else if (items.isEmpty) {
          list = Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text(
                const [
                  'No upcoming interviews. Create one to get started.',
                  'No past interviews yet.',
                  'No favourites yet. Tap the star on an interview to add one.',
                ][_tab],
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            ),
          );
        } else {
          list = Column(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) Divider(height: 1, color: cs.outlineVariant),
                _row(context, items[i], compact: !wide),
              ],
            ],
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (wide)
                    const Text(
                      'Interviews',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  if (wide) const SizedBox(width: 16),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 320),
                        child: TextField(
                          onChanged: (v) => setState(() => _query = v),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Search candidates or roles',
                            prefixIcon: const Icon(Icons.search, size: 18),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _tabs(context, upcoming),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: cs.outlineVariant),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: list,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _tabs(BuildContext context, int upcoming) {
    final cs = Theme.of(context).colorScheme;
    Widget tab(int i, String label, {int? count}) {
      final on = _tab == i;
      return InkWell(
        onTap: () => setState(() => _tab = i),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                width: 2,
                color: on ? cs.primary : Colors.transparent,
              ),
            ),
          ),
          child: Text(
            count == null ? label : '$label  $count',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: on ? cs.onSurface : cs.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(
        children: [
          tab(0, 'Upcoming', count: upcoming),
          tab(1, 'Past'),
          tab(2, 'Favourites'),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    Map<String, dynamic> m, {
    required bool compact,
  }) {
    final cs = Theme.of(context).colorScheme;
    final code = '${m['code']}';
    final candidate = '${m['candidate_name'] ?? ''}'.trim();
    final title = '${m['title'] ?? ''}'.trim();
    final primary = candidate.isNotEmpty
        ? candidate
        : (title.isEmpty ? 'Untitled interview' : title);
    final secondary = candidate.isNotEmpty
        ? title
        : 'Console ${m['console_enabled'] == true ? 'on' : 'off'}';
    final when = _when(m);
    final live = _isLive(m);
    final past = _isPast(m);
    final fav = _isFav(m);
    final later =
        when != null &&
        when.isAfter(DateTime.now().add(const Duration(minutes: 15)));

    Widget action;
    if (live) {
      action = FilledButton(
        onPressed: () => Navigator.of(context).pushNamed('/room/$code'),
        child: const Text('Join room'),
      );
    } else if (past) {
      action = const OutlinedButton(onPressed: null, child: Text('Ended'));
    } else if (later) {
      action = const OutlinedButton(onPressed: null, child: Text('Scheduled'));
    } else {
      action = OutlinedButton(
        onPressed: () => Navigator.of(context).pushNamed('/room/$code'),
        child: const Text('Start'),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: cs.primaryContainer,
            child: Text(
              _initials(primary),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: cs.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  primary,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  secondary,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (live && !compact)
            Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _green.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, size: 8, color: _green),
                  SizedBox(width: 6),
                  Text(
                    'Live now',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _green,
                    ),
                  ),
                ],
              ),
            ),
          if (!live && when != null && !compact)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(_fmt(when), style: const TextStyle(fontSize: 13)),
            ),
          IconButton(
            tooltip: fav ? 'Remove from favourites' : 'Add to favourites',
            icon: Icon(
              fav ? Icons.star : Icons.star_border,
              color: fav ? _amber : cs.onSurfaceVariant,
            ),
            onPressed: () => setState(() {
              if (!_favs.add(code)) _favs.remove(code);
            }),
          ),
          IconButton(
            tooltip: 'Copy candidate link',
            icon: const Icon(Icons.link, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _joinLink(code)));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Link copied')));
            },
          ),
          if (!compact) ...[const SizedBox(width: 8), action],
        ],
      ),
    );
  }
}

// ---------- "New interview" panel ----------

class _NewInterviewForm extends StatefulWidget {
  const _NewInterviewForm({required this.onCreate});
  final Future<bool> Function(String title, String problem, bool console)
  onCreate;

  @override
  State<_NewInterviewForm> createState() => _NewInterviewFormState();
}

class _NewInterviewFormState extends State<_NewInterviewForm> {
  final _title = TextEditingController();
  final _problem = TextEditingController();
  bool _console = true; // default ON so it is not forgotten
  bool _later = false;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _problem.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final ok = await widget.onCreate(
      _title.text.trim(),
      _problem.text.trim(),
      _console,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      _title.clear();
      _problem.clear();
    }
  }

  Widget _label(String text, {String? hint}) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 6),
    child: Text.rich(
      TextSpan(
        text: text,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        children: [
          if (hint != null)
            TextSpan(
              text: ' ($hint)',
              style: TextStyle(
                fontWeight: FontWeight.w400,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    ),
  );

  Widget _seg(String label, bool selected, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? cs.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: selected ? cs.onPrimary : cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'New interview',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          _label('Title'),
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Backend Engineer, Round 1',
              border: OutlineInputBorder(),
            ),
          ),
          _label('Problem statement', hint: 'optional'),
          TextField(
            controller: _problem,
            maxLines: 4,
            decoration: const InputDecoration(
              isDense: true,
              hintText:
                  'Paste or write the question. You can edit it during the call.',
              border: OutlineInputBorder(),
            ),
          ),
          _label('When'),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                _seg(
                  'Start now',
                  !_later,
                  () => setState(() => _later = false),
                ),
                _seg(
                  'Schedule for later',
                  _later,
                  () => setState(() => _later = true),
                ),
              ],
            ),
          ),
          if (_later)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Scheduling needs backend support. Coming in the next step.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            decoration: BoxDecoration(
              border: Border.all(color: cs.outlineVariant),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Code console',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        'On by default. You can switch it during the call.',
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _console,
                  onChanged: (v) => setState(() => _console = v),
                ),
              ],
            ),
          ),
          _label('Send invite to', hint: 'optional'),
          const TextField(
            enabled: false,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'candidate@email.com, recruiter@email.com',
              helperText: 'Email invites are coming in a later step.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: (_busy || _later) ? null : _submit,
              child: Text(_busy ? 'Creating...' : 'Create interview'),
            ),
          ),
        ],
      ),
    );
  }
}
