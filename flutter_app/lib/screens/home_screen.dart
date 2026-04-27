import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/hivemq_service.dart';

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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late HiveMQService _mqttService;
  late TabController _tabController;
  late ScrollController _logScrollController;

  bool isConnected = false;
  bool isPowerOn = false;

  // Door and Scraper now use the new status objects
  DoorStatus _doorStatus = DoorStatus();
  ScraperStatus _scraperStatus = ScraperStatus();

  Motor3Status _motor3Status = Motor3Status();
  Motor4Status _motor4Status = Motor4Status();

  int inCount = 0;
  int outCount = 0;

  String systemMessage = "System Offline";
  final List<LogEntry> _logEntries = [];

  String tab1Name = "MAIN CAGE";
  String tab2Name = "AUX CAGE";

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _logScrollController = ScrollController();
    _loadTabNames();
    _initializeMQTT();
  }

  Future<void> _loadTabNames() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      tab1Name = prefs.getString('tab1_name') ?? "MAIN CAGE";
      tab2Name = prefs.getString('tab2_name') ?? "AUX CAGE";
    });
  }

  Future<void> _saveTabNames() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tab1_name', tab1Name);
    await prefs.setString('tab2_name', tab2Name);
  }

  Color _getStatusColor(String status) {
    if (status.contains("LIMIT") || status.contains("HIT"))
      return Colors.redAccent;
    if (status.contains("TIMEOUT")) return Colors.orange;
    if (status.contains("...") ||
        status.contains("STARTING") ||
        status.contains("REVERSING") ||
        status.contains("OPENING") ||
        status.contains("CLOSING") ||
        status.contains("FORWARD") ||
        status.contains("REVERSE"))
      return Colors.blue;
    if (status.contains("READY") ||
        status.contains("STOPPED") ||
        status.contains("STOPPING"))
      return Colors.green;
    if (status.contains("RUNNING")) return Colors.blue;
    return Colors.grey;
  }

  Future<void> _initializeMQTT() async {
    _mqttService = HiveMQService();

    _mqttService.connectionStatusStream.listen((status) {
      if (!mounted) return;
      setState(() {
        if (status == 'connected') {
          isConnected = true;
          isPowerOn = true;
          _addLog("Connected to HiveMQ", LogType.success);
        } else if (status == 'disconnected') {
          isConnected = false;
          isPowerOn = false;
          _addLog("Disconnected from HiveMQ", LogType.error);
        } else if (status == 'reconnecting') {
          _addLog("Reconnecting...", LogType.warning);
        } else if (status == 'reconnected') {
          isConnected = true;
          isPowerOn = true;
          _addLog("Reconnected to HiveMQ", LogType.success);
        }
      });
    });

    // Listen to door status (new format)
    _mqttService.doorStatusStream.listen((doorStatus) {
      if (!mounted) return;
      setState(() {
        _doorStatus = doorStatus;

        // Update system message
        if (doorStatus.limitHit != 'NONE') {
          systemMessage = "⚠️ Door ${doorStatus.limitHit} HIT";
        } else if (doorStatus.status == 'OPENING') {
          systemMessage = "Door Opening...";
        } else if (doorStatus.status == 'CLOSING') {
          systemMessage = "Door Closing...";
        } else if (_scraperStatus.limitHit != 'NONE') {
          systemMessage = "⚠️ Scraper ${_scraperStatus.limitHit} HIT";
        } else {
          systemMessage = "System Online";
        }
      });
      _addLog("🚪 Door: ${doorStatus.displayText}", LogType.data);
    });

    // Listen to scraper status (new format)
    _mqttService.scraperStatusStream.listen((scraperStatus) {
      if (!mounted) return;
      setState(() {
        _scraperStatus = scraperStatus;

        // Update system message if door not showing limit
        if (_doorStatus.limitHit == 'NONE') {
          if (scraperStatus.limitHit != 'NONE') {
            systemMessage = "⚠️ Scraper ${scraperStatus.limitHit} HIT";
          } else if (scraperStatus.status == 'FORWARD') {
            systemMessage = "Scraper Moving Forward...";
          } else if (scraperStatus.status == 'REVERSE') {
            systemMessage = "Scraper Moving Reverse...";
          } else if (_doorStatus.limitHit == 'NONE') {
            systemMessage = "System Online";
          }
        }
      });
      _addLog("🔄 Scraper: ${scraperStatus.displayText}", LogType.data);
    });

    _mqttService.motor3StatusStream.listen((status) {
      if (!mounted) return;
      setState(() {
        _motor3Status = status;
      });
      _addLog("🔧 Motor 3: ${status.displayText}", LogType.data);
    });

    _mqttService.motor4StatusStream.listen((status) {
      if (!mounted) return;
      setState(() {
        _motor4Status = status;
      });
      _addLog("🔧 Motor 4: ${status.displayText}", LogType.data);
    });

    _mqttService.inCountStream.listen((count) {
      if (!mounted) return;
      setState(() {
        inCount = count;
      });
      _addLog("📥 IN: $count", LogType.data);
    });

    _mqttService.outCountStream.listen((count) {
      if (!mounted) return;
      setState(() {
        outCount = count;
      });
      _addLog("📤 OUT: $count", LogType.data);
    });

    _mqttService.commandResponseStream.listen((response) {
      if (!mounted) return;
      _addLog(response, LogType.command);
    });

    try {
      await _mqttService.connect();
      _addLog("ESP32 Online - Ready", LogType.success);
    } catch (e) {
      _addLog("Failed to connect: $e", LogType.error);
    }
  }

  void _addLog(String message, LogType type) {
    setState(() {
      _logEntries.add(
        LogEntry(message: message, timestamp: DateTime.now(), type: type),
      );
      if (_logEntries.length > 100) {
        _logEntries.removeAt(0);
      }
    });

    Future.delayed(const Duration(milliseconds: 100), () {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _clearLog() {
    setState(() => _logEntries.clear());
    _addLog("Log cleared", LogType.info);
  }

  void _togglePower() {
    setState(() {
      isPowerOn = !isPowerOn;
      if (!isPowerOn) {
        _mqttService.disconnect();
        _addLog("System powered off", LogType.warning);
        systemMessage = "System Offline";
      } else {
        _initializeMQTT();
        _addLog("System powered on", LogType.success);
      }
    });
  }

  void _sendDoorCommand(String command) {
    if (!isPowerOn || !isConnected) {
      _addLog("Cannot send command - system offline", LogType.error);
      return;
    }

    // Check if command is allowed based on limits
    if (command == "START" && !_doorStatus.canMoveUp) {
      _addLog("Cannot OPEN - Door already at UP limit", LogType.error);
      return;
    }
    if (command == "REVERSE" && !_doorStatus.canMoveDown) {
      _addLog("Cannot CLOSE - Door already at DOWN limit", LogType.error);
      return;
    }

    _mqttService.sendDoorCommand(command);
    _addLog("Door: $command", LogType.command);
  }

  void _sendScraperCommand(String command) {
    if (!isPowerOn || !isConnected) {
      _addLog("Cannot send command - system offline", LogType.error);
      return;
    }

    // Check if command is allowed based on limits
    if (command == "START" && !_scraperStatus.canMoveForward) {
      _addLog(
        "Cannot move FORWARD - Scraper already at FRONT limit",
        LogType.error,
      );
      return;
    }
    if (command == "REVERSE" && !_scraperStatus.canMoveReverse) {
      _addLog(
        "Cannot move REVERSE - Scraper already at BACK limit",
        LogType.error,
      );
      return;
    }

    _mqttService.sendScraperCommand(command);
    _addLog("Scraper: $command", LogType.command);
  }

  void _sendMotor3Command(String command) {
    if (!isPowerOn || !isConnected) {
      _addLog("Cannot send command - system offline", LogType.error);
      return;
    }

    // Check limits
    if (command == "START" && !_motor3Status.canMoveForward) {
      _addLog(
        "Cannot move FORWARD - Motor 3 already at FRONT limit",
        LogType.error,
      );
      return;
    }
    if (command == "REVERSE" && !_motor3Status.canMoveReverse) {
      _addLog(
        "Cannot move REVERSE - Motor 3 already at BACK limit",
        LogType.error,
      );
      return;
    }

    _mqttService.sendMotor3Command(command);
    _addLog("Motor 3: $command", LogType.command);
  }

  void _sendMotor4Command(String command) {
    if (!isPowerOn || !isConnected) {
      _addLog("Cannot send command - system offline", LogType.error);
      return;
    }

    // Check limits
    if (command == "START" && !_motor4Status.canMoveForward) {
      _addLog(
        "Cannot move FORWARD - Motor 4 already at FRONT limit",
        LogType.error,
      );
      return;
    }
    if (command == "REVERSE" && !_motor4Status.canMoveReverse) {
      _addLog(
        "Cannot move REVERSE - Motor 4 already at BACK limit",
        LogType.error,
      );
      return;
    }

    _mqttService.sendMotor4Command(command);
    _addLog("Motor 4: $command", LogType.command);
  }

  void _showRenameDialog(int tabIndex) {
    String currentName = tabIndex == 0 ? tab1Name : tab2Name;
    TextEditingController controller = TextEditingController(text: currentName);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A24),
        title: Text('Rename ${tabIndex == 0 ? "Main" : "Aux"} Cage'),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Enter new name',
            hintStyle: TextStyle(color: Colors.grey),
            border: OutlineInputBorder(),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Colors.grey),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF6C5CE7)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                if (tabIndex == 0) {
                  tab1Name = controller.text;
                } else {
                  tab2Name = controller.text;
                }
              });
              _saveTabNames();
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6C5CE7),
            ),
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF0A0A0F),
              const Color(0xFF1A1A24).withOpacity(0.95),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildStatusBar(),
              Expanded(flex: 2, child: _buildLogPanel()),
              _buildTabBar(),
              Expanded(
                flex: 4,
                child: TabBarView(
                  controller: _tabController,
                  children: [_buildMainCageTab(), _buildAuxCageTab()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF6C5CE7), Color(0xFF00B894)],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.agriculture, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'SMART FARM CONTROLLER',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
          ),
          _buildPowerButton(),
        ],
      ),
    );
  }

  Widget _buildPowerButton() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isPowerOn
              ? [const Color(0xFF00B894), const Color(0xFF00CEC9)]
              : [const Color(0xFF636E72), const Color(0xFF2D3436)],
        ),
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          if (isPowerOn)
            BoxShadow(
              color: const Color(0xFF00B894).withOpacity(0.3),
              blurRadius: 10,
              spreadRadius: 1,
            ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _togglePower,
          borderRadius: BorderRadius.circular(30),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isPowerOn ? Icons.power_settings_new : Icons.power_off,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 6),
                Text(
                  isPowerOn ? 'ON' : 'OFF',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    bool isError =
        systemMessage.contains("⚠️") || systemMessage.contains("Offline");
    Color statusColor = isError ? Colors.red : Colors.green;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A24),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withOpacity(0.3), width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: statusColor.withOpacity(0.5),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'SYSTEM',
                  style: TextStyle(
                    fontSize: 9,
                    color: Colors.grey,
                    letterSpacing: 1,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  systemMessage,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (isConnected)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'ONLINE',
                style: TextStyle(
                  color: Colors.green,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLogPanel() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A24),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 14, color: Colors.grey),
                const SizedBox(width: 6),
                const Text(
                  'LOG',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 14),
                  onPressed: _clearLog,
                  color: Colors.grey,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          Expanded(
            child: _logEntries.isEmpty
                ? const Center(
                    child: Text(
                      'No logs',
                      style: TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  )
                : ListView.builder(
                    controller: _logScrollController,
                    padding: const EdgeInsets.all(8),
                    itemCount: _logEntries.length,
                    itemBuilder: (context, index) {
                      final log = _logEntries[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '[${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}]',
                              style: TextStyle(
                                color: _getLogColor(log.type).withOpacity(0.7),
                                fontSize: 9,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                log.message,
                                style: TextStyle(
                                  color: _getLogColor(log.type),
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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

  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      height: 48,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A24),
          borderRadius: BorderRadius.circular(10),
        ),
        child: TabBar(
          controller: _tabController,
          indicatorWeight: 0,
          dividerColor: Colors.transparent,
          indicator: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: const LinearGradient(
              colors: [Color(0xFF6C5CE7), Color(0xFF00B894)],
            ),
          ),
          labelColor: Colors.white,
          unselectedLabelColor: Colors.grey,
          labelStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
          unselectedLabelStyle: const TextStyle(fontSize: 12),
          tabs: [
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.business, size: 14),
                  const SizedBox(width: 4),
                  Text(tab1Name),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () => _showRenameDialog(0),
                    child: const Icon(Icons.edit, size: 12),
                  ),
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.build, size: 14),
                  const SizedBox(width: 4),
                  Text(tab2Name),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () => _showRenameDialog(1),
                    child: const Icon(Icons.edit, size: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainCageTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              _buildCountCard(
                'IN',
                inCount,
                Icons.arrow_downward,
                const Color(0xFF00B894),
              ),
              const SizedBox(width: 12),
              _buildCountCard(
                'OUT',
                outCount,
                Icons.arrow_upward,
                const Color(0xFF0984E3),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // DOOR MOTOR - REMOVED isAtLimit
          _buildMotorTile(
            title: "MAIN DOOR",
            status: _doorStatus.displayText,
            statusColor: _doorStatus.color,
            onStart: () => _sendDoorCommand("START"),
            onReverse: () => _sendDoorCommand("REVERSE"),
            onStop: () => _sendDoorCommand("STOP"),
            isEnabled: isPowerOn && isConnected,
            isAtUpLimit: _doorStatus.limitHit == 'UP LIMIT',
            isAtDownLimit: _doorStatus.limitHit == 'DOWN LIMIT',
          ),
          const SizedBox(height: 12),
          // SCRAPER MOTOR - REMOVED isAtLimit
          _buildMotorTile(
            title: "SCRAPER",
            status: _scraperStatus.displayText,
            statusColor: _scraperStatus.color,
            onStart: () => _sendScraperCommand("START"),
            onReverse: () => _sendScraperCommand("REVERSE"),
            onStop: () => _sendScraperCommand("STOP"),
            isEnabled: isPowerOn && isConnected,
            isAtFrontLimit: _scraperStatus.limitHit == 'FRONT LIMIT',
            isAtBackLimit: _scraperStatus.limitHit == 'BACK LIMIT',
          ),
        ],
      ),
    );
  }

  Widget _buildAuxCageTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // MOTOR 3
          _buildMotorTile(
            title: "MOTOR 3",
            status: _motor3Status.displayText,
            statusColor: _motor3Status.color,
            onStart: () => _sendMotor3Command("START"),
            onReverse: () => _sendMotor3Command("REVERSE"),
            onStop: () => _sendMotor3Command("STOP"),
            isEnabled: isPowerOn && isConnected,
            isAtFrontLimit: _motor3Status.limitHit == 'FRONT LIMIT',
            isAtBackLimit: _motor3Status.limitHit == 'BACK LIMIT',
          ),
          const SizedBox(height: 12),
          // MOTOR 4
          _buildMotorTile(
            title: "MOTOR 4",
            status: _motor4Status.displayText,
            statusColor: _motor4Status.color,
            onStart: () => _sendMotor4Command("START"),
            onReverse: () => _sendMotor4Command("REVERSE"),
            onStop: () => _sendMotor4Command("STOP"),
            isEnabled: isPowerOn && isConnected,
            isAtFrontLimit: _motor4Status.limitHit == 'FRONT LIMIT',
            isAtBackLimit: _motor4Status.limitHit == 'BACK LIMIT',
          ),
        ],
      ),
    );
  }

  Widget _buildCountCard(String label, int count, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [color.withOpacity(0.15), color.withOpacity(0.05)],
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3), width: 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 16),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
            Text(
              count.toString(),
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMotorTile({
    required String title,
    required String status,
    required Color statusColor,
    required VoidCallback onStart,
    required VoidCallback onReverse,
    required VoidCallback onStop,
    required bool isEnabled,
    bool isAtUpLimit = false,
    bool isAtDownLimit = false,
    bool isAtFrontLimit = false,
    bool isAtBackLimit = false,
  }) {
    bool startDisabled = !isEnabled;
    bool reverseDisabled = !isEnabled;

    // DOOR Logic
    if (title == "MAIN DOOR") {
      if (isAtUpLimit) {
        startDisabled = true;
        reverseDisabled = false;
      } else if (isAtDownLimit) {
        startDisabled = false;
        reverseDisabled = true;
      } else {
        startDisabled = !isEnabled;
        reverseDisabled = !isEnabled;
      }
    }
    // SCRAPER Logic
    else if (title == "SCRAPER") {
      if (isAtFrontLimit) {
        startDisabled = true;
        reverseDisabled = false;
      } else if (isAtBackLimit) {
        startDisabled = false;
        reverseDisabled = true;
      } else {
        startDisabled = !isEnabled;
        reverseDisabled = !isEnabled;
      }
    }
    // MOTOR 3 & MOTOR 4 Logic (same as SCRAPER - FRONT/BACK limits)
    else if (title == "MOTOR 3" || title == "MOTOR 4") {
      if (isAtFrontLimit) {
        startDisabled = true; // Can't go forward at FRONT limit
        reverseDisabled = false; // CAN reverse from FRONT limit
      } else if (isAtBackLimit) {
        startDisabled = false; // CAN go forward from BACK limit
        reverseDisabled = true; // Can't reverse at BACK limit
      } else {
        startDisabled = !isEnabled;
        reverseDisabled = !isEnabled;
      }
    }
    // Default (no limits)
    else {
      startDisabled = !isEnabled;
      reverseDisabled = !isEnabled;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A24),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withOpacity(0.3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildActionButton(
                label: "START",
                icon: Icons.play_arrow,
                color: Colors.green,
                onPressed: startDisabled ? null : onStart,
              ),
              const SizedBox(width: 8),
              _buildActionButton(
                label: "REVERSE",
                icon: Icons.swap_horiz,
                color: Colors.orange,
                onPressed: reverseDisabled ? null : onReverse,
              ),
              const SizedBox(width: 8),
              _buildActionButton(
                label: "STOP",
                icon: Icons.stop,
                color: Colors.red,
                onPressed: !isEnabled ? null : onStop,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return Expanded(
      child: Opacity(
        opacity: onPressed == null ? 0.4 : 1.0,
        child: GestureDetector(
          onTap: onPressed,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [color.withOpacity(0.2), color.withOpacity(0.05)],
              ),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withOpacity(0.3)),
            ),
            child: Column(
              children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _logScrollController.dispose();
    _mqttService.dispose();
    super.dispose();
  }
}
