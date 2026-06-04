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

  // Device statuses
  DoorStatus _doorStatus = DoorStatus();
  ScraperStatus _scraperStatus = ScraperStatus();
  FeederStatus _feederStatus = FeederStatus();
  Motor3Status _motor3Status = Motor3Status();
  Motor4Status _motor4Status = Motor4Status();

  // Light, E-Stop, Lockout
  bool _lightOn = false;
  bool _emergencyStopped = false;
  String _lockoutState = 'NONE';

  // Counters
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

  bool get _isDeviceLocked {
    if (_emergencyStopped) return true;
    if (_lockoutState == "ALL" || _lockoutState == "ESTOP") return true;
    if (_lockoutState == "SCHEDULE") return true;
    return false;
  }

  bool _isScraperLocked() {
    if (_emergencyStopped) return true;
    if (_lockoutState == "SCRAPER_CYCLE") return true;
    if (_lockoutState == "ALL" || _lockoutState == "ESTOP") return true;
    return _isDeviceLocked;
  }

  String get _lockoutReason {
    if (_emergencyStopped) return "E-STOP ACTIVE";
    if (_lockoutState == "SCRAPER_CYCLE") return "CYCLE RUNNING";
    if (_lockoutState == "SCHEDULE") return "SCHEDULE RUNNING";
    if (_lockoutState == "ALL" || _lockoutState == "ESTOP") return "LOCKED";
    return "";
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

    _mqttService.doorStatusStream.listen((doorStatus) {
      if (!mounted) return;
      setState(() {
        _doorStatus = doorStatus;
        _updateSystemMessage();
      });
      _addLog("🚪 Door: ${doorStatus.displayText}", LogType.data);
    });

    _mqttService.scraperStatusStream.listen((scraperStatus) {
      if (!mounted) return;
      setState(() {
        _scraperStatus = scraperStatus;
        _updateSystemMessage();
      });
      _addLog("🔄 Scraper: ${scraperStatus.displayText}", LogType.data);
    });

    _mqttService.feederStatusStream.listen((feederStatus) {
      if (!mounted) return;
      setState(() {
        _feederStatus = feederStatus;
      });
      _addLog("🍗 Feeder: ${feederStatus.displayText}", LogType.data);
    });

    _mqttService.lightStatusStream.listen((on) {
      if (!mounted) return;
      setState(() => _lightOn = on);
      _addLog("💡 Light: ${on ? 'ON' : 'OFF'}", LogType.data);
    });

    _mqttService.estopStream.listen((active) {
      if (!mounted) return;
      setState(() {
        _emergencyStopped = active;
        if (active) {
          systemMessage = "🚨 EMERGENCY STOP ACTIVE!";
          _addLog("🚨 E-Stop TRIGGERED!", LogType.error);
        } else {
          _updateSystemMessage();
          _addLog("✅ E-Stop RESET", LogType.success);
        }
      });
    });

    _mqttService.lockoutStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _lockoutState = state;
        if (state == "SCRAPER_CYCLE") {
          _addLog("🔒 Scraper cycle lockout active", LogType.warning);
        }
      });
    });

    _mqttService.motor3StatusStream.listen((status) {
      if (!mounted) return;
      setState(() => _motor3Status = status);
      _addLog("🔧 Motor 3: ${status.displayText}", LogType.data);
    });

    _mqttService.motor4StatusStream.listen((status) {
      if (!mounted) return;
      setState(() => _motor4Status = status);
      _addLog("🔧 Motor 4: ${status.displayText}", LogType.data);
    });

    _mqttService.inCountStream.listen((count) {
      if (!mounted) return;
      setState(() => inCount = count);
      _addLog("📥 IN: $count", LogType.data);
    });

    _mqttService.outCountStream.listen((count) {
      if (!mounted) return;
      setState(() => outCount = count);
      _addLog("📤 OUT: $count", LogType.data);
    });

    _mqttService.commandResponseStream.listen((response) {
      if (!mounted) return;
      _addLog(response, LogType.command);
    });

    _mqttService.scheduleLogStream.listen((log) {
      if (!mounted) return;
      _addLog("⏰ $log", LogType.info);
    });

    try {
      await _mqttService.connect();
      _addLog("ESP32 Online - Ready", LogType.success);
    } catch (e) {
      _addLog("Failed to connect: $e", LogType.error);
    }
  }

  void _updateSystemMessage() {
    if (_emergencyStopped) {
      systemMessage = "🚨 EMERGENCY STOP ACTIVE!";
      return;
    }
    if (_doorStatus.limitHit != 'NONE') {
      systemMessage = "⚠️ Door ${_doorStatus.limitHit} HIT";
    } else if (_scraperStatus.limitHit != 'NONE') {
      systemMessage = "⚠️ Scraper ${_scraperStatus.limitHit} HIT";
    } else if (_doorStatus.status == 'OPENING') {
      systemMessage = "Door Opening...";
    } else if (_doorStatus.status == 'CLOSING') {
      systemMessage = "Door Closing...";
    } else if (_scraperStatus.status == 'FORWARD') {
      systemMessage = "Scraper Moving Forward...";
    } else if (_scraperStatus.status == 'REVERSE') {
      systemMessage = "Scraper Moving Reverse...";
    } else if (_lockoutReason.isNotEmpty) {
      systemMessage = "🔒 $_lockoutReason";
    } else {
      systemMessage = "System Online";
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

  void _handleEStop() {
    if (_emergencyStopped) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A24),
          title: const Text('Reset E-Stop?',
              style: TextStyle(color: Colors.white)),
          content: const Text(
            'Make sure the physical E-Stop button is RELEASED first.',
            style: TextStyle(color: Colors.grey),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCEL', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _mqttService.resetEStop();
                _addLog("E-Stop reset requested", LogType.command);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
              ),
              child: const Text('RESET'),
            ),
          ],
        ),
      );
    } else {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A24),
          title: const Text('⚠️ TRIGGER E-STOP?',
              style: TextStyle(color: Colors.redAccent)),
          content: const Text(
            'This will STOP ALL motors immediately!\nDoor, Scraper, Feeder will all halt.',
            style: TextStyle(color: Colors.grey),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCEL', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _mqttService.triggerEStop();
                _addLog("🚨 E-Stop triggered!", LogType.error);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
              ),
              child: const Text('TRIGGER'),
            ),
          ],
        ),
      );
    }
  }

  void _sendDoorCommand(String command) {
    if (!isPowerOn || !isConnected) {
      _addLog("Cannot send command - system offline", LogType.error);
      return;
    }
    if (_isDeviceLocked) {
      _addLog("Locked: $_lockoutReason", LogType.error);
      return;
    }
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
    if (_isScraperLocked()) {
      String reason = _lockoutState == "SCRAPER_CYCLE"
          ? "CYCLE RUNNING - Only E-Stop can interrupt"
          : _lockoutReason;
      _addLog("Scraper locked: $reason", LogType.error);
      return;
    }
    if (command == "CYCLE") {
      _mqttService.sendScraperCommand("CYCLE");
      _addLog("Scraper: CYCLE requested", LogType.command);
      return;
    }
    if (command == "START" && !_scraperStatus.canMoveForward) {
      _addLog("Cannot move FORWARD - at FRONT limit", LogType.error);
      return;
    }
    if (command == "REVERSE" && !_scraperStatus.canMoveReverse) {
      _addLog("Cannot move REVERSE - at BACK limit", LogType.error);
      return;
    }
    _mqttService.sendScraperCommand(command);
    _addLog("Scraper: $command", LogType.command);
  }

  void _sendFeederCommand(String command) {
    if (!isPowerOn || !isConnected) {
      _addLog("Cannot send command - system offline", LogType.error);
      return;
    }
    if (_isDeviceLocked) {
      _addLog("Locked: $_lockoutReason", LogType.error);
      return;
    }
    if (command == "START" && !_feederStatus.canMoveOpen) {
      _addLog("Cannot OPEN - Feeder at OPEN limit", LogType.error);
      return;
    }
    if (command == "REVERSE" && !_feederStatus.canMoveClose) {
      _addLog("Cannot CLOSE - Feeder at CLOSE limit", LogType.error);
      return;
    }
    _mqttService.sendFeederCommand(command);
    _addLog("Feeder: $command", LogType.command);
  }

  void _toggleLight() {
    if (!isPowerOn || !isConnected) {
      _addLog("Cannot send command - system offline", LogType.error);
      return;
    }
    if (_emergencyStopped) {
      _addLog("Cannot control light during E-Stop", LogType.error);
      return;
    }
    _mqttService.sendLightCommand(_lightOn ? "OFF" : "ON");
    _addLog("Light: ${_lightOn ? 'OFF' : 'ON'}", LogType.command);
  }

  void _sendMotor3Command(String command) {
    if (!isPowerOn || !isConnected) {
      _addLog("Cannot send command - system offline", LogType.error);
      return;
    }
    if (_isDeviceLocked) {
      _addLog("Locked: $_lockoutReason", LogType.error);
      return;
    }
    if (command == "START" && !_motor3Status.canMoveForward) {
      _addLog("Motor 3 at FRONT limit", LogType.error);
      return;
    }
    if (command == "REVERSE" && !_motor3Status.canMoveReverse) {
      _addLog("Motor 3 at BACK limit", LogType.error);
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
    if (_isDeviceLocked) {
      _addLog("Locked: $_lockoutReason", LogType.error);
      return;
    }
    if (command == "START" && !_motor4Status.canMoveForward) {
      _addLog("Motor 4 at FRONT limit", LogType.error);
      return;
    }
    if (command == "REVERSE" && !_motor4Status.canMoveReverse) {
      _addLog("Motor 4 at BACK limit", LogType.error);
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
          // E-Stop Button
          GestureDetector(
            onTap: _handleEStop,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _emergencyStopped
                    ? Colors.redAccent.withOpacity(0.3)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _emergencyStopped
                      ? Colors.redAccent
                      : Colors.grey.withOpacity(0.3),
                ),
              ),
              child: Icon(
                _emergencyStopped ? Icons.warning : Icons.emergency,
                color: _emergencyStopped ? Colors.redAccent : Colors.grey,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 8),
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
        systemMessage.contains("⚠️") ||
        systemMessage.contains("Offline") ||
        systemMessage.contains("🚨");
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
                if (_lockoutReason.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      '🔒 $_lockoutReason',
                      style: const TextStyle(
                        color: Colors.orange,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
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
    bool feederLocked = _isDeviceLocked;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Chicken count cards
          Row(
            children: [
              _buildCountCard(
                'IN', inCount, Icons.arrow_downward, const Color(0xFF00B894)),
              const SizedBox(width: 12),
              _buildCountCard(
                'OUT', outCount, Icons.arrow_upward, const Color(0xFF0984E3)),
            ],
          ),
          const SizedBox(height: 16),

          // Light toggle card
          _buildLightTile(),
          const SizedBox(height: 12),

          // DOOR MOTOR
          _buildMotorTile(
            title: "MAIN DOOR",
            status: _doorStatus.displayText,
            statusColor: _doorStatus.color,
            onStart: () => _sendDoorCommand("START"),
            onReverse: () => _sendDoorCommand("REVERSE"),
            onStop: () => _sendDoorCommand("STOP"),
            isEnabled: isPowerOn && isConnected && !_isDeviceLocked,
            isLocked: _isDeviceLocked,
            lockReason: _lockoutReason,
            isAtUpLimit: _doorStatus.limitHit == 'UP LIMIT',
            isAtDownLimit: _doorStatus.limitHit == 'DOWN LIMIT',
          ),
          const SizedBox(height: 12),

          // SCRAPER MOTOR
          _buildMotorTile(
            title: "SCRAPER",
            status: _scraperStatus.displayText,
            statusColor: _scraperStatus.color,
            onStart: () => _sendScraperCommand("START"),
            onReverse: () => _sendScraperCommand("REVERSE"),
            onStop: () => _sendScraperCommand("STOP"),
            extraButton: _buildActionButton(
              label: "CYCLE",
              icon: Icons.loop,
              color: Colors.purple,
              onPressed: !isPowerOn || !isConnected || _isScraperLocked()
                  ? null
                  : () => _sendScraperCommand("CYCLE"),
            ),
            isEnabled: isPowerOn && isConnected && !_isScraperLocked(),
            isLocked: _isScraperLocked(),
            lockReason: _lockoutState == "SCRAPER_CYCLE"
                ? "CYCLE RUNNING"
                : _lockoutReason,
            isAtFrontLimit: _scraperStatus.limitHit == 'FRONT LIMIT',
            isAtBackLimit: _scraperStatus.limitHit == 'BACK LIMIT',
          ),
          const SizedBox(height: 12),

          // FEEDER MOTOR
          _buildMotorTile(
            title: "FEEDER",
            status: _feederStatus.displayText,
            statusColor: _feederStatus.color,
            onStart: () => _sendFeederCommand("START"),
            onReverse: () => _sendFeederCommand("REVERSE"),
            onStop: () => _sendFeederCommand("STOP"),
            isEnabled: isPowerOn && isConnected && !feederLocked,
            isLocked: feederLocked,
            lockReason: _lockoutReason,
            isAtUpLimit: _feederStatus.limitHit == 'OPEN LIMIT',
            isAtDownLimit: _feederStatus.limitHit == 'CLOSE LIMIT',
          ),
        ],
      ),
    );
  }

  Widget _buildLightTile() {
    bool disabled = !isPowerOn || !isConnected || _emergencyStopped;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _lightOn
            ? const Color(0xFF1A1A24)
            : const Color(0xFF1A1A24),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _lightOn
              ? const Color(0xFFFDCB6E).withOpacity(0.5)
              : Colors.grey.withOpacity(0.2),
        ),
        boxShadow: _lightOn
            ? [
                BoxShadow(
                  color: const Color(0xFFFDCB6E).withOpacity(0.1),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          Icon(
            _lightOn ? Icons.lightbulb : Icons.lightbulb_outline,
            color: _lightOn ? const Color(0xFFFDCB6E) : Colors.grey,
            size: 28,
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CAGE LIGHT',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '12V bulb',
                  style: TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ),
          ),
          Switch(
            value: _lightOn,
            onChanged: disabled ? null : (_) => _toggleLight(),
            activeColor: const Color(0xFFFDCB6E),
            activeTrackColor: const Color(0xFFFDCB6E).withOpacity(0.3),
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
          _buildMotorTile(
            title: "MOTOR 3",
            status: _motor3Status.displayText,
            statusColor: _motor3Status.color,
            onStart: () => _sendMotor3Command("START"),
            onReverse: () => _sendMotor3Command("REVERSE"),
            onStop: () => _sendMotor3Command("STOP"),
            isEnabled: isPowerOn && isConnected && !_isDeviceLocked,
            isLocked: _isDeviceLocked,
            lockReason: _lockoutReason,
            isAtFrontLimit: _motor3Status.limitHit == 'FRONT LIMIT',
            isAtBackLimit: _motor3Status.limitHit == 'BACK LIMIT',
          ),
          const SizedBox(height: 12),
          _buildMotorTile(
            title: "MOTOR 4",
            status: _motor4Status.displayText,
            statusColor: _motor4Status.color,
            onStart: () => _sendMotor4Command("START"),
            onReverse: () => _sendMotor4Command("REVERSE"),
            onStop: () => _sendMotor4Command("STOP"),
            isEnabled: isPowerOn && isConnected && !_isDeviceLocked,
            isLocked: _isDeviceLocked,
            lockReason: _lockoutReason,
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
    bool isLocked = false,
    String lockReason = '',
    bool isAtUpLimit = false,
    bool isAtDownLimit = false,
    bool isAtFrontLimit = false,
    bool isAtBackLimit = false,
    Widget? extraButton,
  }) {
    bool startDisabled = !isEnabled;
    bool reverseDisabled = !isEnabled;

    // DOOR Logic
    if (title == "MAIN DOOR") {
      if (isAtUpLimit) { startDisabled = true; reverseDisabled = false; }
      else if (isAtDownLimit) { startDisabled = false; reverseDisabled = true; }
      else { startDisabled = !isEnabled; reverseDisabled = !isEnabled; }
    }
    // SCRAPER Logic
    else if (title == "SCRAPER") {
      if (isAtFrontLimit) { startDisabled = true; reverseDisabled = false; }
      else if (isAtBackLimit) { startDisabled = false; reverseDisabled = true; }
      else { startDisabled = !isEnabled; reverseDisabled = !isEnabled; }
    }
    // FEEDER Logic (OPEN/CLOSE like UP/DOWN)
    else if (title == "FEEDER") {
      if (isAtUpLimit) { startDisabled = true; reverseDisabled = false; }
      else if (isAtDownLimit) { startDisabled = false; reverseDisabled = true; }
      else { startDisabled = !isEnabled; reverseDisabled = !isEnabled; }
    }
    // MOTOR 3 & 4 Logic
    else if (title == "MOTOR 3" || title == "MOTOR 4") {
      if (isAtFrontLimit) { startDisabled = true; reverseDisabled = false; }
      else if (isAtBackLimit) { startDisabled = false; reverseDisabled = true; }
      else { startDisabled = !isEnabled; reverseDisabled = !isEnabled; }
    }

    Color borderColor = isLocked
        ? Colors.redAccent.withOpacity(0.5)
        : statusColor.withOpacity(0.3);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A24),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: isLocked ? 2 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  if (isLocked) ...[
                    const Icon(Icons.lock, color: Colors.redAccent, size: 14),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: isLocked ? Colors.redAccent : Colors.white,
                    ),
                  ),
                ],
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
          if (lockReason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '🔒 $lockReason',
              style: const TextStyle(
                color: Colors.orange,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
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
              if (extraButton != null) ...[
                const SizedBox(width: 8),
                extraButton,
              ],
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
