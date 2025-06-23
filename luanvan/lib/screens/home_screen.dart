import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'add_food_screen.dart';
import 'recipe_suggestion_screen.dart';
import 'food_detail_screen.dart';
import 'cart_screen.dart';
import 'config.dart';
import 'package:intl/intl.dart';

// Cache for API responses
final Map<String, String> _nameCache = {};

class HomeScreen extends StatefulWidget {
  final String uid;
  final String token;
  const HomeScreen({super.key, required this.uid, required this.token});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  String _filter = 'Tất cả';
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  String? _selectedAreaId;
  String _selectedAreaName = 'Tất cả';
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late FlutterLocalNotificationsPlugin _notificationsPlugin;
  bool _isLoading = true;
  final Color primaryColor = const Color(0xFF0078D7);
  final Color textLightColor = const Color(0xFF5F6368);
  final Set<String> _notifiedLogs = {};
  List<Map<String, dynamic>> _storageLogs = [];
  List<Map<String, dynamic>> _storageAreas = [];
  final DateFormat _dateFormat = DateFormat('dd/MM/yyyy');
  final DateFormat _customDateFormat = DateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'");

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _initializeNotifications();
    _fetchInitialData();
    _animationController.forward();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.uid != oldWidget.uid) _fetchInitialData();
  }

  Future<void> _fetchInitialData() async {
    setState(() => _isLoading = true);
    try {
      await Future.wait([
        _fetchStorageAreas(),
        _fetchStorageLogs(),
      ]);
    } catch (e) {
      print('Error fetching initial data: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _initializeNotifications() {
    _notificationsPlugin = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    _notificationsPlugin.initialize(initSettings);
  }

  Future<void> _showNotification(String title, String body, int id) async {
    const androidDetails = AndroidNotificationDetails(
      'food_expiry_channel',
      'Food Expiry Notifications',
      channelDescription: 'Thông báo về thực phẩm sắp hết hạn hoặc đã hết hạn',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
    );
    const notificationDetails = NotificationDetails(android: androidDetails);
    await _notificationsPlugin.show(id, title, body, notificationDetails);
  }

  Future<void> _deleteExpiredLogs() async {
    setState(() => _isLoading = true);
    try {
      final now = DateTime.now();
      final cutoffDate = now.subtract(const Duration(days: 30));
      final expiredDocs = await _firestore
          .collection('StorageLogs')
          .where('userId', isEqualTo: widget.uid)
          .where('expiryDate', isLessThan: Timestamp.fromDate(cutoffDate))
          .get();

      for (var doc in expiredDocs.docs) {
        await _firestore.collection('StorageLogs').doc(doc.id).delete();
      }
      await _showNotification(
        'Dọn dẹp hoàn tất',
        'Đã xóa các thực phẩm hết hạn quá lâu!',
        0,
      );
      await _fetchStorageLogs();
    } catch (e) {
      print('Lỗi khi xóa: $e');
      await _showNotification(
        'Lỗi',
        'Không thể xóa dữ liệu, vui lòng thử lại!',
        1,
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchStorageAreas() async {
    try {
      final url = Uri.parse('${Config.getNgrokUrl()}/get_storage_areas');
      final response = await http.get(
        url,
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final areas = List<Map<String, dynamic>>.from(data['areas'] ?? []);
        if (mounted) {
          setState(() {
            _storageAreas = areas;
            print('Fetched ${_storageAreas.length} storage areas');
          });
        }
      } else {
        throw Exception('Failed to fetch storage areas: ${response.body}');
      }
    } catch (e) {
      print('Error fetching storage areas: $e');
    }
  }

  Future<void> _fetchStorageLogs() async {
    setState(() => _isLoading = true);
    try {
      final url = Uri.parse(
          '${Config.getNgrokUrl()}/get_sorted_storage_logs?userId=${widget.uid}${_selectedAreaId != null ? '&areaId=$_selectedAreaId' : ''}');
      print('Fetching storage logs from: $url');
      final response = await http.get(
        url,
        headers: {'Content-Type': 'application/json'},
      );

      print('API response status: ${response.statusCode}, body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final logs = List<Map<String, dynamic>>.from(data['logs'] ?? []);
        print('Fetched ${logs.length} storage logs');

        final processedLogs = logs.map((log) {
          final expiryDateString = log['expiryDate'] as String?;
          final storageDateString = log['storageDate'] as String?;
          DateTime? expiryDate;
          DateTime? storageDate;

          // Hàm hỗ trợ parse chuỗi ngày giờ
          DateTime? parseDateTime(String? dateString) {
            if (dateString == null || dateString.isEmpty) return null;
            try {
              // Xử lý định dạng không chuẩn (loại bỏ hậu tố kép)
              String cleanedDateString = dateString.replaceAll(RegExp(r'\+00:00\+07:00$'), '+07:00');
              return DateTime.parse(cleanedDateString).toLocal();
            } catch (e) {
              print('Error parsing date "$dateString": $e');
              return null;
            }
          }

          expiryDate = parseDateTime(expiryDateString);
          storageDate = parseDateTime(storageDateString);

          return {
            ...log,
            'expiryDate': expiryDate,
            'storageDate': storageDate,
          };
        }).toList();

        if (mounted) {
          setState(() {
            _storageLogs = processedLogs;
            _isLoading = false;
            print('Updated _storageLogs with ${processedLogs.length} items');
            print('Filtered logs: ${_storageLogs.where((log) => _selectedAreaId == null || log['areaId'] == _selectedAreaId).length} items');
          });
        }
      } else {
        throw Exception('Failed to fetch storage logs: ${response.body}');
      }
    } catch (e) {
      print('Error fetching storage logs: $e');
      if (mounted) {
        setState(() {
          _storageLogs = [];
          _isLoading = false;
        });
      }
    }
  }

  void _selectArea(String? areaId, String areaName) {
    setState(() {
      _selectedAreaId = areaId;
      _selectedAreaName = areaName;
      print('Selected area: id=$areaId, name=$areaName');
      print('Current storage logs: ${_storageLogs.length} items');
      print('Filtered logs: ${_storageLogs.where((log) => _selectedAreaId == null || log['areaId'] == _selectedAreaId).length} items');
    });
    _fetchStorageLogs();
  }

  IconData getIconForArea(String areaName) {
    switch (areaName.toLowerCase()) {
      case 'ngăn mát':
        return Icons.local_dining;
      case 'ngăn đá':
        return Icons.ac_unit;
      case 'ngăn cửa':
        return Icons.local_cafe;
      case 'kệ trên':
        return Icons.shelves;
      case 'kệ dưới':
        return Icons.kitchen;
      default:
        return Icons.inventory_2_outlined;
    }
  }

  int _getExpiringItemsCount(List<Map<String, dynamic>> logs) {
    final now = DateTime.now();
    return logs.where((log) {
      final expiryDate = log['expiryDate'] as DateTime?;
      if (expiryDate == null) return false;
      final daysLeft = expiryDate.difference(now).inDays;
      return daysLeft <= 3 && daysLeft >= 0;
    }).length;
  }

  int _getExpiredLongAgoCount(List<Map<String, dynamic>> logs) {
    final now = DateTime.now();
    final cutoffDate = now.subtract(const Duration(days: 30));
    return logs.where((log) {
      final expiryDate = log['expiryDate'] as DateTime?;
      return expiryDate != null && expiryDate.isBefore(cutoffDate);
    }).length;
  }

  void _showRecipeSuggestions(List<Map<String, dynamic>> storageLogs) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RecipeSuggestionScreen(
          foodItems: storageLogs,
          userId: widget.uid,
        ),
      ),
    );
  }

  Future<void> _deleteLog(String logId) async {
    try {
      final response = await http.delete(
        Uri.parse('${Config.getNgrokUrl()}/delete_storage_log/$logId'),
        headers: {'Content-Type': 'application/json'},
      );
      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã xóa thực phẩm!')),
        );
        await _fetchStorageLogs();
      } else {
        throw Exception('Xóa thất bại: ${response.body}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi khi xóa: $e')),
      );
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final Color secondaryColor = const Color(0xFF50E3C2);
    final Color accentColor = const Color(0xFF00B294);

    List<Map<String, dynamic>> filteredStorageLogs = _selectedAreaId == null
        ? _storageLogs
        : _storageLogs.where((log) => log['areaId'] == _selectedAreaId).toList();

    filteredStorageLogs.sort((a, b) => (a['areaName'] ?? 'Unknown Area')
        .compareTo(b['areaName'] ?? 'Unknown Area'));

    return Scaffold(
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _fetchInitialData,
            color: primaryColor,
            backgroundColor: Colors.white,
            child: CustomScrollView(
              slivers: [
                SliverAppBar(
                  pinned: true,
                  expandedHeight: 180.0,
                  backgroundColor: Colors.transparent,
                  leading: IconButton(
                    icon: const Icon(Icons.menu, color: Colors.white),
                    onPressed: () {},
                  ),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.shopping_cart, color: Colors.white),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => CartScreen(
                              userId: widget.uid,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                  flexibleSpace: FlexibleSpaceBar(
                    background: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [primaryColor, const Color(0xFF0056B3), accentColor],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          stops: const [0.0, 0.7, 1.0],
                        ),
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(32),
                          bottomRight: Radius.circular(32),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: primaryColor.withOpacity(0.3),
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        gradient: RadialGradient(
                                          colors: [accentColor, primaryColor],
                                          radius: 0.8,
                                        ),
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: accentColor.withOpacity(0.3),
                                            blurRadius: 8,
                                            offset: const Offset(0, 3),
                                          ),
                                        ],
                                      ),
                                      child: Icon(
                                        getIconForArea(_selectedAreaName),
                                        color: Colors.white,
                                        size: 28,
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        ShaderMask(
                                          shaderCallback: (bounds) => LinearGradient(
                                            colors: [Colors.white, Colors.white.withOpacity(0.8)],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ).createShader(bounds),
                                          child: const Text(
                                            'SmartFri',
                                            style: TextStyle(
                                              fontSize: 24,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          'Quản lý thông minh',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.white.withOpacity(0.8),
                                            fontWeight: FontWeight.w500,
                                            letterSpacing: 0.3,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.white.withOpacity(0.2)),
                            ),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  _buildAreaFilter(null, 'Tất cả', Icons.apps),
                                  ..._storageAreas.map((area) => _buildAreaFilter(
                                    area['id'] as String?,
                                    area['name'] as String,
                                    getIconForArea(area['name'] as String),
                                  )),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Colors.white, Color(0xFFFAFDFF)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.08),
                                blurRadius: 20,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _selectedAreaId == null
                                              ? 'Chào mừng trở lại!'
                                              : 'Khu vực: $_selectedAreaName',
                                          style: TextStyle(
                                            fontSize: 22,
                                            fontWeight: FontWeight.w800,
                                            color: const Color(0xFF202124),
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          _selectedAreaId == null
                                              ? 'Bạn có ${_storageLogs.length} món trong tủ lạnh'
                                              : 'Có ${filteredStorageLogs.length} món trong $_selectedAreaName',
                                          style: TextStyle(
                                            fontSize: 16,
                                            color: textLightColor,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          primaryColor.withOpacity(0.1),
                                          accentColor.withOpacity(0.1)
                                        ],
                                      ),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Icon(
                                      _selectedAreaId == null
                                          ? Icons.inventory_2_outlined
                                          : getIconForArea(_selectedAreaName),
                                      color: primaryColor,
                                      size: 32,
                                    ),
                                  ),
                                ],
                              ),
                              if (_getExpiringItemsCount(filteredStorageLogs) > 0)
                                Column(
                                  children: [
                                    const SizedBox(height: 16),
                                    Container(
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [Colors.orange[50]!, Colors.orange[100]!],
                                        ),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(color: Colors.orange[200]!),
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(
                                              color: Colors.orange[100]!,
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            child: Icon(
                                              Icons.warning_amber_outlined,
                                              color: Colors.orange[700]!,
                                              size: 20,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              '${_getExpiringItemsCount(filteredStorageLogs)} món sắp hết hạn trong $_selectedAreaName!',
                                              style: TextStyle(
                                                color: Colors.orange[800]!,
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'Thao tác nhanh',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: const Color(0xFF202124),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _buildQuickActionCard(
                                icon: Icons.add_circle_outline,
                                title: 'Thêm thực phẩm',
                                color: primaryColor,
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => AddFoodScreen(
                                        uid: widget.uid,
                                        token: widget.token,
                                      ),
                                    ),
                                  ).then((value) async {
                                    if (value == true) {
                                      await _fetchStorageLogs();
                                    }
                                  });
                                },
                                sizeFactor: 0.9,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: _buildQuickActionCard(
                                icon: Icons.restaurant_menu_outlined,
                                title: 'Gợi ý món ăn',
                                color: accentColor,
                                onTap: () => _showRecipeSuggestions(_storageLogs),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _selectedAreaId == null
                                  ? 'Thực phẩm gần đây'
                                  : 'Thực phẩm trong $_selectedAreaName',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: const Color(0xFF202124),
                              ),
                            ),
                            if (_getExpiredLongAgoCount(filteredStorageLogs) > 0)
                              TextButton(
                                onPressed: _deleteExpiredLogs,
                                child: const Text(
                                  'Xóa hết hạn cũ',
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                        (context, index) {
                      if (index >= filteredStorageLogs.length) {
                        print('No logs to display, filteredStorageLogs is empty');
                        return const SizedBox.shrink();
                      }
                      final log = filteredStorageLogs[index];
                      print('Rendering log at index $index: ${log['id']}');
                      return _buildFoodItem(log);
                    },
                    childCount: filteredStorageLogs.length,
                  ),
                ),
                if (_storageLogs.isEmpty || filteredStorageLogs.isEmpty)
                  SliverFillRemaining(
                    child: Center(child: _buildEmptyState()),
                  ),
              ],
            ),
          ),
          if (_isLoading)
            Container(
              color: Colors.black.withOpacity(0.3),
              child: const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0078D7)),
                  strokeWidth: 4.0,
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: primaryColor.withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: FloatingActionButton.extended(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => AddFoodScreen(
                  uid: widget.uid,
                  token: widget.token,
                ),
              ),
            ).then((value) async {
              if (value == true) {
                await _fetchStorageLogs();
              }
            });
          },
          backgroundColor: primaryColor,
          icon: const Icon(Icons.add, color: Colors.white, size: 24),
          label: const Text(
            'Thêm',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          elevation: 0,
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      height: 200,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Colors.white, Color(0xFFF8FFFE)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                _selectedAreaId == null ? Icons.inventory_2 : getIconForArea(_selectedAreaName),
                size: 48,
                color: Colors.grey[400],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _storageLogs.isEmpty
                  ? 'Chưa có thực phẩm nào'
                  : 'Không có thực phẩm trong $_selectedAreaName',
              style: TextStyle(
                fontSize: 18,
                color: Colors.grey[600],
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _storageLogs.isEmpty
                  ? 'Thêm thực phẩm đầu tiên của bạn!'
                  : 'Thêm thực phẩm vào khu vực này!',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[500],
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActionCard({
    required IconData icon,
    required String title,
    required Color color,
    required VoidCallback onTap,
    double sizeFactor = 1.0,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(20 * sizeFactor),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Colors.white, Color(0xFFFAFDFF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.2)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.all(16 * sizeFactor),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [color.withOpacity(0.1), color.withOpacity(0.05)],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                icon,
                color: color,
                size: 28 * sizeFactor,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                fontSize: 18 * sizeFactor,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF202124),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFoodItem(Map<String, dynamic> log) {
    final logId = log['id'] as String?;
    if (logId == null) {
      print('Skipping log with null id: $log');
      return const SizedBox.shrink();
    }

    final foodName = log['foodName'] as String? ?? 'Unknown Food';
    final storageDate = log['storageDate'] as DateTime?;
    final expiryDate = log['expiryDate'] as DateTime?;
    final areaName = log['areaName'] as String? ?? 'Unknown Area';
    final quantity = log['quantity']?.toString() ?? '0';
    final unitName = log['unitName'] as String? ?? 'Unknown Unit';

    print('Building food item: $logId, expiryDate: $expiryDate, storageDate: $storageDate, foodName: $foodName, areaName: $areaName, quantity: $quantity, unitName: $unitName');

    final daysLeft = expiryDate != null ? expiryDate.difference(DateTime.now()).inDays : 999;

    Color statusColor = Colors.green;
    String statusText = 'Tươi';
    IconData statusIcon = Icons.check_circle;

    if (daysLeft <= 0) {
      statusColor = Colors.red;
      statusText = 'Hết hạn';
      statusIcon = Icons.error;
    } else if (daysLeft <= 3) {
      statusColor = Colors.orange;
      statusText = 'Sắp hết hạn';
      statusIcon = Icons.warning;
    } else if (expiryDate == null) {
      statusColor = Colors.grey;
      statusText = 'Không rõ';
      statusIcon = Icons.help;
    }

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => FoodDetailScreen(
              storageLogId: logId,
              userId: widget.uid,
              initialLog: log,
            ),
          ),
        ).then((value) async {
          if (value is Map<String, dynamic>) {
            if (value['refreshFoods'] == true && value['foodId'] != null) {
              _nameCache['food_${value['foodId']}'] = value['foodName'] ?? 'Unknown';
            }
            if (value['refreshStorageLogs'] == true) {
              await _fetchStorageLogs();
            }
          }
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Colors.white, Color(0xFFFAFDFF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [statusColor.withOpacity(0.1), statusColor.withOpacity(0.05)],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                getIconForArea(areaName),
                color: statusColor,
                size: 28,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    foodName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF202124),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Khu vực: $areaName',
                    style: TextStyle(
                      fontSize: 14,
                      color: textLightColor,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Số lượng: $quantity $unitName',
                    style: TextStyle(
                      fontSize: 14,
                      color: textLightColor,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Hết hạn: ${expiryDate != null ? _dateFormat.format(expiryDate) : 'Không rõ'}',
                    style: TextStyle(
                      fontSize: 14,
                      color: textLightColor,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Ngày tạo: ${storageDate != null ? _dateFormat.format(storageDate) : 'Không rõ'}',
                    style: TextStyle(
                      fontSize: 14,
                      color: textLightColor,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [statusColor.withOpacity(0.1), statusColor.withOpacity(0.05)],
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, color: statusColor, size: 16),
                      const SizedBox(width: 4),
                      Text(
                        statusText,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: statusColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () async {
                    final shouldDelete = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Xác nhận'),
                        content: const Text('Bạn có chắc muốn xóa thực phẩm này?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Hủy'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Xóa'),
                          ),
                        ],
                      ),
                    );
                    if (shouldDelete == true) {
                      await _deleteLog(logId);
                    }
                  },
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: 0.6,
                    child: const Icon(
                      Icons.delete_outline,
                      color: Colors.red,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAreaFilter(String? areaId, String areaName, IconData icon) {
    final isSelected = _selectedAreaId == areaId;
    return GestureDetector(
      onTap: () => _selectArea(areaId, areaName),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white.withOpacity(0.3) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: isSelected ? Border.all(color: Colors.white, width: 2) : null,
          boxShadow: isSelected
              ? [
            BoxShadow(
              color: Colors.white.withOpacity(0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: Colors.white,
              size: isSelected ? 28 : 24,
            ),
            const SizedBox(height: 4),
            Text(
              areaName,
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}