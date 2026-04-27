import 'package:flutter/material.dart';

enum LogType { info, success, warning, error, command, data }

class LogEntry {
  final String message;
  final DateTime timestamp;
  final LogType type;

  LogEntry({
    required this.message,
    required this.timestamp,
    required this.type,
  });
}

class LogPanel extends StatefulWidget {
  final List<LogEntry> entries;
  final VoidCallback onClear;
  final ScrollController scrollController;

  const LogPanel({
    super.key,
    required this.entries,
    required this.onClear,
    required this.scrollController,
  });

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 200,
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A24),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 18, color: Colors.grey),
                const SizedBox(width: 8),
                const Text(
                  'SYSTEM LOG',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: widget.onClear,
                  color: Colors.grey,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          Expanded(
            child: widget.entries.isEmpty
                ? const Center(
                    child: Text(
                      'No logs yet',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    controller: widget.scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: widget.entries.length,
                    itemBuilder: (context, index) {
                      final log = widget.entries[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '[${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}]',
                              style: TextStyle(
                                color: _getLogColor(log.type).withOpacity(0.7),
                                fontSize: 10,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                log.message,
                                style: TextStyle(
                                  color: _getLogColor(log.type),
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Color _getLogColor(LogType type) {
    switch (type) {
      case LogType.success:
        return const Color(0xFF00B894);
      case LogType.error:
        return const Color(0xFFD63031);
      case LogType.warning:
        return const Color(0xFFFDCB6E);
      case LogType.command:
        return const Color(0xFF6C5CE7);
      case LogType.data:
        return const Color(0xFF0984E3);
      default:
        return Colors.grey;
    }
  }
}
