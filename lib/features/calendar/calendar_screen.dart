import 'package:flutter/material.dart';

import '../../di.dart';
import '../../domain/entities/calendar.dart';
import '../../domain/entities/task.dart';
import '../../domain/repositories/calendar_entry_repository.dart';
import '../../domain/repositories/task_repository.dart';
import 'widgets/entry_edit_dialog.dart';

/// 日历视图粒度。
enum CalendarViewMode {
  /// 日视图。
  day,

  /// 周视图。
  week,

  /// 月视图。
  month,
}

/// 日历页：日/周/月三视图，日程与当日截止任务统一展示。
class CalendarScreen extends StatefulWidget {
  /// 创建日历页。
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  static const List<String> _weekdayLabels = <String>[
    '一',
    '二',
    '三',
    '四',
    '五',
    '六',
    '日',
  ];

  final CalendarEntryRepository _calendarRepository =
      getIt<CalendarEntryRepository>();
  final TaskRepository _taskRepository = getIt<TaskRepository>();

  CalendarViewMode _mode = CalendarViewMode.day;

  /// 当前定位日期（当天 00:00）。
  late DateTime _anchor;

  /// 区间流随视图与定位日期重订阅。
  late Stream<List<CalendarEntry>> _entriesStream;

  /// 任务全量流：本地按 dueAt 过滤，不下推查询。
  late final Stream<List<Task>> _tasksStream =
      _taskRepository.watchTasks(const TaskQuery());

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _anchor = DateTime(now.year, now.month, now.day);
    _resubscribe();
  }

  /// 按当前视图与定位日期重算区间流。
  void _resubscribe() {
    _entriesStream = _calendarRepository.watchInRange(_rangeStart, _rangeEnd);
  }

  DateTime get _rangeStart {
    switch (_mode) {
      case CalendarViewMode.day:
        return _anchor;
      case CalendarViewMode.week:
        return _weekStart;
      case CalendarViewMode.month:
        return DateTime(_anchor.year, _anchor.month, 1);
    }
  }

  DateTime get _rangeEnd {
    switch (_mode) {
      case CalendarViewMode.day:
        return DateTime(_anchor.year, _anchor.month, _anchor.day + 1);
      case CalendarViewMode.week:
        return DateTime(_weekStart.year, _weekStart.month, _weekStart.day + 7);
      case CalendarViewMode.month:
        return DateTime(_anchor.year, _anchor.month + 1, 1);
    }
  }

  /// 当前周的周一。
  DateTime get _weekStart =>
      DateTime(_anchor.year, _anchor.month, _anchor.day - (_anchor.weekday - 1));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('日历'),
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<CalendarViewMode>(
              segments: const <ButtonSegment<CalendarViewMode>>[
                ButtonSegment<CalendarViewMode>(
                  value: CalendarViewMode.day,
                  label: Text('日'),
                ),
                ButtonSegment<CalendarViewMode>(
                  value: CalendarViewMode.week,
                  label: Text('周'),
                ),
                ButtonSegment<CalendarViewMode>(
                  value: CalendarViewMode.month,
                  label: Text('月'),
                ),
              ],
              selected: <CalendarViewMode>{_mode},
              onSelectionChanged: (selection) {
                setState(() {
                  _mode = selection.first;
                  _resubscribe();
                });
              },
            ),
          ),
          _buildPeriodHeader(),
          Expanded(
            child: StreamBuilder<List<CalendarEntry>>(
              stream: _entriesStream,
              builder: (context, entriesSnapshot) {
                final entries =
                    entriesSnapshot.data ?? const <CalendarEntry>[];
                return StreamBuilder<List<Task>>(
                  stream: _tasksStream,
                  builder: (context, tasksSnapshot) {
                    final tasks = tasksSnapshot.data ?? const <Task>[];
                    switch (_mode) {
                      case CalendarViewMode.day:
                        return _buildDayView(entries, tasks);
                      case CalendarViewMode.week:
                        return _buildWeekView(entries, tasks);
                      case CalendarViewMode.month:
                        return _buildMonthView(entries, tasks);
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        // 壳内 IndexedStack 多 FAB 同处一个路由子树，禁用默认 Hero tag。
        heroTag: null,
        onPressed: () => _createEntry(_anchor),
        child: const Icon(Icons.add),
      ),
    );
  }

  /// 周期标题与前后翻页。
  Widget _buildPeriodHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: <Widget>[
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: '上一页',
            onPressed: () => _shift(-1),
          ),
          Expanded(
            child: Text(
              _periodLabel,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: '下一页',
            onPressed: () => _shift(1),
          ),
        ],
      ),
    );
  }

  /// 按视图粒度前后翻页。
  void _shift(int direction) {
    setState(() {
      switch (_mode) {
        case CalendarViewMode.day:
          _anchor =
              DateTime(_anchor.year, _anchor.month, _anchor.day + direction);
        case CalendarViewMode.week:
          _anchor = DateTime(
            _anchor.year,
            _anchor.month,
            _anchor.day + direction * 7,
          );
        case CalendarViewMode.month:
          _anchor = DateTime(_anchor.year, _anchor.month + direction, 1);
      }
      _resubscribe();
    });
  }

  String get _periodLabel {
    switch (_mode) {
      case CalendarViewMode.day:
        return _formatDate(_anchor);
      case CalendarViewMode.week:
        final start = _weekStart;
        final end = DateTime(start.year, start.month, start.day + 6);
        return '${_formatMonthDay(start)} ~ ${_formatMonthDay(end)}';
      case CalendarViewMode.month:
        return '${_anchor.year} 年 ${_anchor.month} 月';
    }
  }

  // ---------------------------------------------------------------------------
  // 日视图
  // ---------------------------------------------------------------------------

  Widget _buildDayView(List<CalendarEntry> entries, List<Task> tasks) {
    final dayEntries = _entriesOn(entries, _anchor);
    final dayTasks = _tasksDueOn(tasks, _anchor);
    if (dayEntries.isEmpty && dayTasks.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '这一天还没有安排，点右下角按钮添加',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    final morning = dayEntries.where((e) => e.startAt.hour < 12).toList();
    final afternoon =
        dayEntries.where((e) => e.startAt.hour >= 12 && e.startAt.hour < 18).toList();
    final evening = dayEntries.where((e) => e.startAt.hour >= 18).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
      children: <Widget>[
        if (morning.isNotEmpty) ..._buildDaySection('上午', morning),
        if (afternoon.isNotEmpty) ..._buildDaySection('下午', afternoon),
        if (evening.isNotEmpty) ..._buildDaySection('晚上', evening),
        if (dayTasks.isNotEmpty) ..._buildDayTaskSection(dayTasks),
      ],
    );
  }

  List<Widget> _buildDaySection(String title, List<CalendarEntry> entries) {
    return <Widget>[
      _sectionLabel(title),
      for (final entry in entries) _buildEntryCard(entry),
    ];
  }

  List<Widget> _buildDayTaskSection(List<Task> tasks) {
    return <Widget>[
      _sectionLabel('当日任务'),
      for (final task in tasks)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: const Icon(Icons.check_circle_outline, color: Colors.orange),
            title: Text(
              task.title,
              style: TextStyle(
                decoration: _isClosed(task) ? TextDecoration.lineThrough : null,
                color: _isClosed(task) ? Colors.grey : Colors.black87,
              ),
            ),
            subtitle: Text(
              '截止 ${_hhmm(task.dueAt!)}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ),
    ];
  }

  Widget _buildEntryCard(CalendarEntry entry) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => _editEntry(entry),
        leading: const Icon(Icons.event, color: Colors.blue),
        title: Text(entry.title),
        subtitle: Text(
          entry.allDay ? '全天' : '${_hhmm(entry.startAt)}–${_hhmm(entry.endAt)}',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 13,
          color: Colors.grey,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 周视图
  // ---------------------------------------------------------------------------

  Widget _buildWeekView(List<CalendarEntry> entries, List<Task> tasks) {
    final start = _weekStart;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List<Widget>.generate(7, (i) {
        final day = DateTime(start.year, start.month, start.day + i);
        return Expanded(
          child: _buildWeekColumn(
            day,
            _entriesOn(entries, day),
            _tasksDueOn(tasks, day),
          ),
        );
      }),
    );
  }

  Widget _buildWeekColumn(
    DateTime day,
    List<CalendarEntry> entries,
    List<Task> tasks,
  ) {
    final isToday = _isSameDay(day, DateTime.now());
    return Container(
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: isToday ? Colors.blue.shade50 : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            onTap: () => _createEntry(day),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: <Widget>[
                  Text(
                    _weekdayLabels[day.weekday - 1],
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  Text(
                    '${day.day}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isToday ? Colors.blue : Colors.black87,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              children: <Widget>[
                for (final entry in entries) _buildWeekChip(entry),
                for (final task in tasks) _buildWeekTaskChip(task),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWeekChip(CalendarEntry entry) {
    return InkWell(
      onTap: () => _editEntry(entry),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          entry.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: Colors.blue),
        ),
      ),
    );
  }

  Widget _buildWeekTaskChip(Task task) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        task.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          color: Colors.orange,
          decoration: _isClosed(task) ? TextDecoration.lineThrough : null,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 月视图
  // ---------------------------------------------------------------------------

  Widget _buildMonthView(List<CalendarEntry> entries, List<Task> tasks) {
    final first = DateTime(_anchor.year, _anchor.month, 1);
    final daysInMonth = DateTime(_anchor.year, _anchor.month + 1, 0).day;
    final leading = first.weekday - 1;
    final rows = ((leading + daysInMonth) / 7).ceil();
    return Column(
      children: <Widget>[
        _buildWeekdayHeader(),
        Expanded(
          child: ListView.builder(
            itemCount: rows,
            itemBuilder: (context, row) {
              return SizedBox(
                height: 96,
                child: Row(
                  children: List<Widget>.generate(7, (col) {
                    final index = row * 7 + col;
                    final dayNum = index - leading + 1;
                    if (index < leading || dayNum > daysInMonth) {
                      return const Expanded(child: SizedBox());
                    }
                    final day = DateTime(_anchor.year, _anchor.month, dayNum);
                    return _buildMonthCell(
                      day,
                      _entriesOn(entries, day),
                      _tasksDueOn(tasks, day),
                    );
                  }),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildWeekdayHeader() {
    return Row(
      children: <Widget>[
        for (final label in _weekdayLabels)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMonthCell(
    DateTime day,
    List<CalendarEntry> entries,
    List<Task> tasks,
  ) {
    final isToday = _isSameDay(day, DateTime.now());
    final labels = <String>[
      ...entries.map((e) => e.title),
      ...tasks.map((t) => t.title),
    ];
    final colors = <Color>[
      ...entries.map((_) => Colors.blue),
      ...tasks.map((_) => Colors.orange),
    ];
    final shown = labels.length > 3 ? labels.sublist(0, 3) : labels;
    final hidden = labels.length - shown.length;
    return Expanded(
      child: InkWell(
        onTap: () => _createEntry(day),
        child: Container(
          margin: const EdgeInsets.all(1),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade200),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '${day.day}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                  color: isToday ? Colors.blue : Colors.black87,
                ),
              ),
              const SizedBox(height: 2),
              for (var i = 0; i < shown.length; i++)
                Container(
                  margin: const EdgeInsets.only(bottom: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                  decoration: BoxDecoration(
                    color: colors[i].withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    shown[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: colors[i]),
                  ),
                ),
              if (hidden > 0)
                Text(
                  '+$hidden',
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 查询与操作
  // ---------------------------------------------------------------------------

  /// 命中 [day] 的日程（半开区间已由仓储保证，这里只按起始日归属）。
  List<CalendarEntry> _entriesOn(List<CalendarEntry> entries, DateTime day) {
    return entries.where((e) => _isSameDay(e.startAt, day)).toList()
      ..sort((a, b) {
        final compared = a.startAt.compareTo(b.startAt);
        return compared != 0 ? compared : a.id.compareTo(b.id);
      });
  }

  /// 截止于 [day] 的任务（含已完成/已取消，由样式区分）。
  List<Task> _tasksDueOn(List<Task> tasks, DateTime day) {
    return tasks
        .where((t) => t.dueAt != null && _isSameDay(t.dueAt!, day))
        .toList();
  }

  /// 新建日程，预填 [date]。
  Future<void> _createEntry(DateTime date) async {
    await EntryEditDialog.show(context, initialDate: date);
  }

  /// 编辑已有日程。
  Future<void> _editEntry(CalendarEntry entry) async {
    await EntryEditDialog.show(context, entry: entry);
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _isClosed(Task task) =>
      task.status == TaskStatus.done || task.status == TaskStatus.cancelled;

  String _formatDate(DateTime dt) =>
      '${dt.year}-${_two(dt.month)}-${_two(dt.day)}';

  String _formatMonthDay(DateTime dt) => '${dt.month}月${dt.day}日';

  String _hhmm(DateTime dt) => '${_two(dt.hour)}:${_two(dt.minute)}';

  String _two(int value) => value.toString().padLeft(2, '0');
}
