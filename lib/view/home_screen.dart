import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/folder_info.dart';
import '../service/disk_scanner_service.dart';
import '../service/windows_drive_service.dart';

class DiskScannerScreen extends StatefulWidget {
  final VoidCallback onToggleTheme;
  const DiskScannerScreen({super.key, required this.onToggleTheme});
  @override
  State<DiskScannerScreen> createState() => _DiskScannerScreenState();
}

class _DiskScannerScreenState extends State<DiskScannerScreen> {
  final DiskScannerService _scannerService = DiskScannerService();
  bool _isScanning = false;
  bool _isScanComplete = false;
  double _progress = 0.0;
  final List<FolderInfo> _scanResults = [];
  List<FolderInfo> _displayList = [];
  String? _errorMessage;
  String _selectedDrive = 'C:\\';

  double _totalDiskSpaceGB = 0.0;
  double _freeDiskSpaceGB = 0.0;

  List<PieChartSectionData> _pieChartData = [];
  Map<String, double> _barChartData = {};
  double _foundFoldersSizeGB = 0;

  @override
  void initState() {
    super.initState();
    _scannerService.scanEventsStream.listen((event) {
      if (!mounted) return;
      switch (event['type']) {
        case 'progress':
          setState(() => _progress = (event['value'] as int) / 100.0);
          break;
        case 'result':
          _addResult(
            FolderInfo(path: event['path'], sizeInBytes: event['size']),
          );
          break;
        case 'complete':
          setState(() {
            _isScanning = false;
            _isScanComplete = true;
            if (_progress < 1.0) _progress = 1.0;
            _processDataForCharts();
          });
          break;
      }
    });
  }

  void _addResult(FolderInfo newResult) {
    // Rule 1: Check if the new result is a subfolder of an existing result.
    if (_scanResults.any(
      (existing) =>
          newResult.path.startsWith(existing.path) &&
          newResult.path != existing.path,
    )) {
      return;
    }

    // Rule 2: Check if the new result is a parent of any existing results.
    _scanResults.removeWhere(
      (existing) =>
          existing.path.startsWith(newResult.path) &&
          newResult.path != existing.path,
    );

    _scanResults.add(newResult);

    setState(() {
      _scanResults.sort((a, b) => b.sizeInBytes.compareTo(a.sizeInBytes));
      _buildDisplayList();
    });
  }

  @override
  void dispose() {
    _scannerService.stopScan();
    super.dispose();
  }

  Future<void> _startScan() async {
    final driveInfo = await WindowsDriveService.getDriveInfo(_selectedDrive);
    if (driveInfo != null) {
      _totalDiskSpaceGB = driveInfo.totalGB;
      _freeDiskSpaceGB = driveInfo.freeGB;
    } else {
      _totalDiskSpaceGB = 0;
      _freeDiskSpaceGB = 0;
      print("Could not retrieve disk space info for $_selectedDrive");
    }
    setState(() {
      _isScanning = true;
      _isScanComplete = false;
      _scanResults.clear();
      _displayList.clear();
      _progress = 0.0;
      _errorMessage = null;
    });
    await _scannerService.startScan(_selectedDrive);
  }

  void _buildDisplayList() {
    _displayList = [];
    for (var folder in _scanResults) {
      _addFolderToDisplayList(folder);
    }
  }

  void _addFolderToDisplayList(FolderInfo folder) {
    _displayList.add(folder);
    if (folder.isExpanded) {
      for (var child in folder.children) {
        _addFolderToDisplayList(child);
      }
    }
  }

  void _stopScan() {
    _scannerService.stopScan();
    setState(() => _isScanning = false);
  }

  Future<void> _toggleFolderExpansion(FolderInfo folder) async {
    if (folder.children.isNotEmpty) {
      setState(() {
        folder.isExpanded = !folder.isExpanded;
        _buildDisplayList();
      });
      return;
    }
    setState(() {
      folder.isExpanded = true;
      folder.isLoading = true;
      _buildDisplayList();
    });
    final children = await _scannerService.scanSubdirectory(folder.path);
    folder.children = children
        .map(
          (c) => FolderInfo(
            path: c.path,
            sizeInBytes: c.sizeInBytes,
            level: folder.level + 1,
          ),
        )
        .toList();
    folder.isLoading = false;
    setState(() => _buildDisplayList());
  }

  void _processDataForCharts() {
    if (_totalDiskSpaceGB == 0) return;
    final totalFoundBytes = _scanResults.fold<int>(
      0,
      (sum, item) => sum + item.sizeInBytes,
    );
    _foundFoldersSizeGB = totalFoundBytes / (1024 * 1024 * 1024);
    final double usedDiskSpaceGB = _totalDiskSpaceGB - _freeDiskSpaceGB;
    final double otherUsedGB = usedDiskSpaceGB - _foundFoldersSizeGB;
    _pieChartData = [
      PieChartSectionData(
        value: _foundFoldersSizeGB,
        title: '${_foundFoldersSizeGB.toStringAsFixed(1)} GB',
        color: Colors.redAccent,
        radius: 60,
        titleStyle: const TextStyle(
          fontWeight: FontWeight.bold,
          color: Colors.white,
          fontSize: 12,
        ),
      ),
      PieChartSectionData(
        value: otherUsedGB > 0 ? otherUsedGB : 0,
        title: '',
        color: Colors.orange.shade700,
        radius: 60,
      ),
      PieChartSectionData(
        value: _freeDiskSpaceGB,
        title: '',
        color: Colors.blue.shade800,
        radius: 60,
      ),
    ];
    final userProfile =
        Platform.environment['USERPROFILE']?.toLowerCase() ?? '';
    _barChartData = {};
    for (var folder in _scanResults) {
      final category = _classifyFolder(folder.path.toLowerCase(), userProfile);
      _barChartData[category] =
          (_barChartData[category] ?? 0) +
          (folder.sizeInBytes / (1024 * 1024 * 1024));
    }
  }

  String _classifyFolder(String path, String userProfile) {
    if (path.contains(r'appdata')) return 'Apps';
    if (path.contains(r'steam') ||
        path.contains(r'epic games') ||
        path.contains(r'origin'))
      return 'Games';
    if (userProfile.isNotEmpty &&
        (path.contains(r'\downloads') || path.contains(r'\documents')))
      return 'Docs';
    if (path.contains(r'\temp') || path.contains(r'\cache')) return 'Cache';
    return 'Other';
  }

  Future<void> _openFolder(String path) async {
    final uri = Uri.file(path);
    if (!await launchUrl(uri)) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not open folder: $path')));
    }
  }

  List<String> _getDrives() {
    final drives = <String>[];
    for (int i = 65; i <= 90; i++) {
      final driveLetter = String.fromCharCode(i);
      final drivePath = '$driveLetter:\\';
      if (Directory(drivePath).existsSync()) {
        drives.add(drivePath);
      }
    }
    return drives.isNotEmpty ? drives : ['C:\\'];
  }

  void _show_about() {
    showAboutDialog(
      context: context,
      applicationName: 'Disk Scanner',
      applicationVersion: '0.2.0 (Beta)',
      applicationIcon: Icon(Icons.info_outline),
      children: [
        Column(
          children: [
            TextButton(
              onPressed: () async {
                final url = Uri.parse("https://github.com/mortza-mansory");
                if (await canLaunchUrl(url)) {
                  await launchUrl(url);
                } else {
                  debugPrint("Could not launch $url");
                }
              },
              child: Text("Creator: mortza mansory"),
            ),
            Text('This app scans your disk and shows usage statistics.'),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final drives = _getDrives();
    if (!drives.contains(_selectedDrive)) {
      _selectedDrive = drives.first;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Disk Scanner'),
        actions: [
          IconButton(
            icon: const Icon(Icons.brightness_6),
            onPressed: widget.onToggleTheme,
            tooltip: 'Toggle Theme',
          ),
          IconButton(
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: _show_about,
            tooltip: 'Toggle Theme',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  value: _selectedDrive,
                  items: drives
                      .map(
                        (String drive) => DropdownMenuItem<String>(
                          value: drive,
                          child: Text('Drive $drive'),
                        ),
                      )
                      .toList(),
                  onChanged: _isScanning
                      ? null
                      : (String? newValue) =>
                            setState(() => _selectedDrive = newValue!),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Select Drive',
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 3,
                child: ElevatedButton.icon(
                  onPressed: _isScanning ? _stopScan : _startScan,
                  icon: Icon(
                    _isScanning ? Icons.stop_circle_outlined : Icons.play_arrow,
                  ),
                  label: Text(_isScanning ? 'Stop Scan' : 'Start Scan'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: _isScanning
                        ? Colors.red.shade700
                        : Theme.of(context).colorScheme.primary,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          if (_isScanning)
            Padding(
              padding: const EdgeInsets.only(top: 16.0),
              child: LinearProgressIndicator(value: _progress),
            ),
          if (_isScanComplete) _buildChartsSection(),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(
                'Error: $_errorMessage',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 16.0),
            child: Text(
              'Large Folders:',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const Divider(),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _displayList.length > 0 ? _displayList.length : 1,
            itemBuilder: (context, index) {
              if (_displayList.isEmpty) {
                return Center(
                  heightFactor: 5,
                  child: Text(
                    _isScanning
                        ? 'Scanning...'
                        : 'Press "Start Scan" to begin.',
                  ),
                );
              }
              final folder = _displayList[index];
              return Card(
                margin: EdgeInsets.only(
                  left: folder.level * 24.0,
                  top: 4,
                  bottom: 4,
                  right: 0,
                ),
                child: ListTile(
                  leading: folder.isLoading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        )
                      : Icon(
                          folder.isExpanded ? Icons.folder_open : Icons.folder,
                          color: Colors.orange,
                        ),
                  title: Text(
                    folder.level > 0
                        ? folder.path.split(r'\').last
                        : folder.path,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(folder.readableSize),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.open_in_new),
                        onPressed: () => _openFolder(folder.path),
                        tooltip: 'Open in Explorer',
                      ),
                      IconButton(
                        icon: Icon(
                          folder.isExpanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                        ),
                        onPressed: () => _toggleFolderExpansion(folder),
                        tooltip: 'Show large subfolders',
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildChartsSection() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 600) {
            return Column(
              children: [
                _buildPieChartCard(),
                const SizedBox(height: 16),
                _buildBarChartCard(),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 2, child: _buildPieChartCard()),
              const SizedBox(width: 16),
              Expanded(flex: 3, child: _buildBarChartCard()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPieChartCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Text(
              'Drive: ${_totalDiskSpaceGB.toStringAsFixed(1)} GB',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 220,
              child: PieChart(
                PieChartData(
                  sections: _pieChartData,
                  centerSpaceRadius: 0,
                  sectionsSpace: 2,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _Indicator(
              color: Colors.redAccent,
              text: 'Found (${_foundFoldersSizeGB.toStringAsFixed(1)} GB)',
            ),
            _Indicator(color: Colors.orange.shade700, text: 'Other Used'),
            _Indicator(
              color: Colors.blue.shade800,
              text: 'Free (${_freeDiskSpaceGB.toStringAsFixed(1)} GB)',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBarChartCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Text(
              'Categories (GB)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 285,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  barGroups: _barChartData.entries
                      .map(
                        (e) => BarChartGroupData(
                      x: e.key.hashCode,
                      barRods: [
                        BarChartRodData(
                          toY: e.value,
                          width: 15,
                          borderRadius: BorderRadius.circular(4),
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ],
                    ),
                  )
                      .toList(),
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) => Text(
                          _barChartData.keys.firstWhere(
                                (k) => k.hashCode == value,
                            orElse: () => '',
                          ),
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 30,
                      ),
                    ),
                    topTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  gridData: FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

  class _Indicator extends StatelessWidget {
  final Color color;
  final String text;
  const _Indicator({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4.0),
      child: Row(
        children: <Widget>[
          Container(width: 12, height: 12, color: color),
          const SizedBox(width: 8),
          Text(text, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
