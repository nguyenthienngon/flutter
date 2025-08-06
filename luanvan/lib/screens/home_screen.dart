import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:luanvan/screens/welcome_screen.dart';
import 'package:workmanager/workmanager.dart';
import 'dart:io' show Platform;
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'add_food_screen.dart';
import 'meal_plan.dart';
import 'recipe_suggestion_screen.dart';
import 'food_detail_screen.dart';
import 'cart_screen.dart';
import 'config.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:shimmer/shimmer.dart';

// Cache for API responses with expiration
final Map<String, String> _nameCache = {};
final Set<String> _notifiedLogs = {};
DateTime? _lastCacheClear = DateTime.now();

void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final FirebaseFirestore firestore = FirebaseFirestore.instance;
      final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);
      await flutterLocalNotificationsPlugin.initialize(initSettings);
      final String userId = inputData?['userId'] ?? "defaultUserId";
      final now = DateTime.now().toUtc().add(const Duration(hours: 7));
      final dateFormat = DateFormat('dd/MM/yyyy');
      final snapshot = await firestore
          .collection('StorageLogs')
          .where('userId', isEqualTo: userId)
          .limit(50)
          .get();
      final List<Map<String, dynamic>> storageLogs = snapshot.docs.map((doc) {
        final data = doc.data();
        DateTime? expiryDate = data['expiryDate'] is Timestamp
            ? (data['expiryDate'] as Timestamp).toDate().toLocal()
            : _parseDateTime(data['expiryDate'] as String?);
        return {
          ...data,
          'id': doc.id,
          'expiryDate': expiryDate,
          'status': _getStatus(expiryDate),
        };
      }).toList();
      final expiringItems = storageLogs.where((log) {
        final expiryDate = log['expiryDate'] as DateTime?;
        if (expiryDate == null) return false;
        final daysLeft = expiryDate.difference(now).inDays;
        return daysLeft >= 0 && daysLeft <= 3;
      }).toList();
      for (var item in expiringItems) {
        final logId = item['id'] as String;
        final foodName = item['foodName'] as String? ?? 'Unknown Food';
        final expiryDate = item['expiryDate'] as DateTime?;
        await _showNotificationStatic(
          flutterLocalNotificationsPlugin,
          'Thực phẩm sắp hết hạn',
          '$foodName sẽ hết hạn vào ${dateFormat.format(expiryDate ?? now)}!',
          logId.hashCode,
          logId,
        );
        _notifiedLogs.add(logId);
      }
      final expiredItems = storageLogs.where((log) {
        final expiryDate = log['expiryDate'] as DateTime?;
        return expiryDate != null && expiryDate.isBefore(now);
      }).toList();
      for (var item in expiredItems) {
        final logId = item['id'] as String;
        final foodName = item['foodName'] as String? ?? 'Unknown Food';
        final expiryDate = item['expiryDate'] as DateTime?;
        await _showNotificationStatic(
          flutterLocalNotificationsPlugin,
          'Thực phẩm đã hết hạn',
          '$foodName đã hết hạn vào ${dateFormat.format(expiryDate ?? now)}!',
          logId.hashCode,
          logId,
        );
        _notifiedLogs.add(logId);
      }
      return Future.value(true);
    } catch (e) {
      print('Error in background task: $e');
      return Future.value(false);
    }
  });
}

DateTime? _parseDateTime(String? dateString) {
  if (dateString == null || dateString.isEmpty) return null;
  try {
    String cleanedDateString = dateString
        .replaceAll(RegExp(r'\+00:00\+07:00$'), '+07:00')
        .replaceAll(RegExp(r'Z$'), '+07:00');
    return DateTime.parse(cleanedDateString).toLocal();
  } catch (e) {
    print('Error parsing date "$dateString": $e');
    return null;
  }
}

String _getStatus(DateTime? expiryDate) {
  if (expiryDate == null) return 'unknown';
  final now = DateTime.now().toUtc().add(const Duration(hours: 7));
  final daysLeft = expiryDate.difference(now).inDays;
  if (daysLeft < 0) return 'expired';
  if (daysLeft <= 3) return 'expiring';
  return 'fresh';
}

Future<void> _showNotificationStatic(
    FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin,
    String title,
    String body,
    int id,
    String storageLogId,
    ) async {
  try {
    const androidDetails = AndroidNotificationDetails(
      'food_expiry_channel',
      'Food Expiry Notifications',
      channelDescription: 'Thông báo về thực phẩm sắp hết hạn hoặc đã hết hạn',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
    );
    const notificationDetails = NotificationDetails(android: androidDetails);
    await flutterLocalNotificationsPlugin.show(
      id,
      title,
      body,
      notificationDetails,
      payload: 'view_details_$storageLogId',
    );
  } catch (e) {
    print('Error showing notification: $e');
  }
}

enum SortOption { category, expiryDate, createdDate, fresh, expiring, expired, name }

class HomeScreen extends StatefulWidget {
  final String uid;
  final String token;
  const HomeScreen({super.key, required this.uid, required this.token});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  String? _selectedAreaId;
  String _selectedAreaName = 'Tất cả';
  String? _selectedFridgeId;
  String _selectedFridgeName = '';
  List<Map<String, dynamic>> _fridges = [];
  late AnimationController _animationController;
  late AnimationController _fabAnimationController;
  late AnimationController _shimmerController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _slideAnimation;
  late FlutterLocalNotificationsPlugin _notificationsPlugin;
  bool _isLoggingOut = false;
  bool _isLoading = true;
  bool _isDeletingExpired = false;
  bool _isDarkMode = false;
  bool _isSearchVisible = false;
  String _searchQuery = '';
  SortOption _selectedSort = SortOption.category;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<String> _searchSuggestions = [];
  final List<String> _searchHistory = [];
  List<Map<String, dynamic>> _units = [];
  List<Map<String, dynamic>> _pendingInvitations = [];

  // Enhanced color scheme
  final Color primaryColor = const Color(0xFF2196F3);
  final Color secondaryColor = const Color(0xFF00BCD4);
  final Color accentColor = const Color(0xFF4CAF50);
  final Color successColor = const Color(0xFF4CAF50);
  final Color warningColor = const Color(0xFFFF9800);
  final Color errorColor = const Color(0xFFF44336);
  final Color backgroundColor = const Color(0xFFF8FAFC);
  final Color surfaceColor = Colors.white;
  final Color textPrimaryColor = const Color(0xFF1A202C);
  final Color textSecondaryColor = const Color(0xFF718096);
  final Color darkBackgroundColor = const Color(0xFF0F172A);
  final Color darkSurfaceColor = const Color(0xFF1E293B);
  final Color darkTextPrimaryColor = const Color(0xFFF1F5F9);
  final Color darkTextSecondaryColor = const Color(0xFFCBD5E1);

  // Enhanced action colors
  final Color addFoodColor = const Color(0xFF3B82F6);
  final Color recipeColor = const Color(0xFF10B981);
  final Color shoppingColor = const Color(0xFF8B5CF6);
  final Color mealPlanColor = const Color(0xFFF59E0B);

  List<Map<String, dynamic>> _storageLogs = [];
  List<Map<String, dynamic>> _storageAreas = [];
  final DateFormat _dateFormat = DateFormat('dd/MM/yyyy');
  int _currentPage = 0;
  static const int _pageSize = 20;
  Timer? _searchDebounce;

  Color get currentBackgroundColor => _isDarkMode ? darkBackgroundColor : backgroundColor;
  Color get currentSurfaceColor => _isDarkMode ? darkSurfaceColor : surfaceColor;
  Color get currentTextPrimaryColor => _isDarkMode ? darkTextPrimaryColor : textPrimaryColor;
  Color get currentTextSecondaryColor => _isDarkMode ? darkTextSecondaryColor : textSecondaryColor;

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _initializeNotifications();
    _initializeWorkManager();
    _fetchInitialData();
    _scrollController.addListener(_onScroll);
    _clearCacheIfNeeded();
  }

  void _clearCacheIfNeeded() {
    final now = DateTime.now();
    if (_lastCacheClear == null || now.difference(_lastCacheClear!).inHours >= 24) {
      _nameCache.clear();
      _notifiedLogs.clear();
      _lastCacheClear = now;
    }
  }

  void _initializeAnimations() {
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _fabAnimationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _shimmerController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _slideAnimation = Tween<double>(begin: 30.0, end: 0.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _animationController.forward();
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _fabAnimationController.forward();
    });
  }

  Future<void> _initializeWorkManager() async {
    try {
      await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
      await Workmanager().registerPeriodicTask(
        "check-expiry-task",
        "checkExpiryTask",
        frequency: const Duration(hours: 24),
        inputData: {'userId': widget.uid},
        initialDelay: const Duration(minutes: 1),
      );
    } catch (e) {
      print('Error initializing WorkManager: $e');
    }
  }

  Future<void> _initializeNotifications() async {
    try {
      _notificationsPlugin = FlutterLocalNotificationsPlugin();
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);
      await _notificationsPlugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) async {
          if (response.payload != null && response.payload!.startsWith('view_details_')) {
            final storageLogId = response.payload!.replaceFirst('view_details_', '');
            await _handleNotificationTap(storageLogId);
          }
        },
      );
      if (Platform.isAndroid) {
        var status = await Permission.notification.status;
        if (status.isDenied) {
          await Permission.notification.request();
        }
      }
    } catch (e) {
      print('Error initializing notifications: $e');
    }
  }

  Future<void> _handleNotificationTap(String storageLogId) async {
    try {
      final logDoc = await _firestore.collection('StorageLogs').doc(storageLogId).get();
      if (logDoc.exists && mounted) {
        final logData = logDoc.data()!;
        DateTime? expiryDate = logData['expiryDate'] is Timestamp
            ? (logData['expiryDate'] as Timestamp).toDate().toLocal()
            : _parseDateTime(logData['expiryDate'] as String?);
        DateTime? storageDate = logData['storageDate'] is Timestamp
            ? (logData['storageDate'] as Timestamp).toDate().toLocal()
            : _parseDateTime(logData['storageDate'] as String?);
        final initialLog = {
          ...logData,
          'id': storageLogId,
          'expiryDate': expiryDate,
          'storageDate': storageDate,
          'status': _getStatus(expiryDate),
        };
        final foodId = logData['foodId'] as String?;
        String? foodName;
        if (foodId != null) {
          if (_nameCache.containsKey('food_$foodId')) {
            foodName = _nameCache['food_$foodId'];
          } else {
            final foodDoc = await _firestore.collection('Foods').doc(foodId).get();
            if (foodDoc.exists) {
              foodName = foodDoc.data()?['name'] as String? ?? 'Unknown Food';
              _nameCache['food_$foodId'] = foodName;
            }
          }
        }
        initialLog['foodName'] = foodName ?? logData['foodName'] ?? 'Unknown Food';
        if (mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => FoodDetailScreen(
                storageLogId: storageLogId,
                userId: widget.uid,
                initialLog: initialLog,
                isDarkMode: _isDarkMode,
              ),
            ),
          ).then((value) async {
            if (value is Map<String, dynamic>) {
              if (value['refreshFoods'] == true && value['foodId'] != null) {
                _nameCache['food_${value['foodId']}'] = value['foodName'] ?? 'Unknown Food';
              }
              if (value['refreshStorageLogs'] == true) {
                await _fetchStorageLogs(page: 0);
              }
            }
          });
        }
      } else {
        print('StorageLog $storageLogId not found or widget not mounted');
      }
    } catch (e) {
      print('Error handling notification tap: $e');
    }
  }

  Future<void> _fetchInitialData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _storageLogs.clear();
      _currentPage = 0;
    });
    try {
      await Future.wait([
        _fetchFridges(),
        _fetchStorageLogs(page: 0),
        _fetchUnits(),
        _fetchPendingInvitations(),
      ]);
      if (_fridges.isEmpty && mounted) {
        await _showAddFridgeDialog();
        if (_fridges.isEmpty) {
          _showErrorSnackBar('Vui lòng thêm ít nhất một tủ lạnh để tiếp tục.');
          setState(() => _isLoading = false);
          return;
        }
      }
      await _fetchStorageAreas();
    } catch (e) {
      print('Error fetching initial data: $e');
      if (mounted) _showErrorSnackBar('Lỗi khi tải dữ liệu: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchUnits() async {
    try {
      final unitsSnapshot = await _firestore.collection('Units').get();
      if (mounted) {
        setState(() {
          _units = unitsSnapshot.docs
              .map((doc) => {...doc.data(), 'id': doc.id})
              .toList();
          print('Fetched ${_units.length} units: ${_units.map((e) => e['name']).join(", ")}');
        });
      }
    } catch (e) {
      print('Error fetching units: $e');
      if (mounted) _showErrorSnackBar('Lỗi khi tải danh sách đơn vị: $e');
    }
  }

  Future<void> _fetchPendingInvitations() async {
    try {
      final snapshot = await _firestore
          .collection('PendingInvitations')
          .where('inviteeId', isEqualTo: widget.uid)
          .where('status', isEqualTo: 'pending')
          .get();
      if (mounted) {
        setState(() {
          _pendingInvitations = snapshot.docs
              .map((doc) => {...doc.data(), 'id': doc.id})
              .toList();
          print('Fetched ${_pendingInvitations.length} pending invitations');
        });
      }
    } catch (e) {
      print('Error fetching pending invitations: $e');
      if (mounted) _showErrorSnackBar('Lỗi khi tải danh sách lời mời: $e');
    }
  }

  Future<void> _fetchStorageAreas() async {
    if (_selectedFridgeId == null) {
      if (mounted) {
        setState(() {
          _storageAreas = [];
          _selectedAreaId = null;
          _selectedAreaName = 'Tất cả';
        });
      }
      return;
    }
    try {
      final url = Uri.parse('${Config.getNgrokUrl()}/get_storage_areas?userId=${Uri.encodeComponent(widget.uid)}&fridgeId=${Uri.encodeComponent(_selectedFridgeId!)}');
      final response = await http.get(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final areas = List<Map<String, dynamic>>.from(data['areas'] ?? []);
        if (mounted) {
          setState(() {
            _storageAreas = areas.map((area) {
              return {
                'id': area['id'] ?? '',
                'name': area['name'] ?? 'Unknown Area',
                'fridgeId': area['fridgeId'] ?? _selectedFridgeId,
              };
            }).toList();
            _selectedAreaId = null;
            _selectedAreaName = 'Tất cả';
            print('Fetched ${_storageAreas.length} storage areas for fridge $_selectedFridgeId: ${_storageAreas.map((e) => e['name']).join(", ")}');
          });
        }
      } else {
        throw Exception('Failed to fetch storage areas: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      print('Error fetching storage areas for fridge $_selectedFridgeId: $e');
      if (mounted) {
        setState(() {
          _storageAreas = [];
          _selectedAreaId = null;
          _selectedAreaName = 'Tất cả';
        });
        _showErrorSnackBar('Lỗi khi tải danh sách khu vực: $e');
      }
    }
  }

  Future<void> _fetchFridges() async {
    try {
      final snapshot = await _firestore
          .collection('Fridges')
          .where('ownerId', isEqualTo: widget.uid)
          .get();
      final sharedSnapshot = await _firestore
          .collection('Fridges')
          .where('sharedWith', arrayContains: widget.uid)
          .get();
      if (mounted) {
        setState(() {
          _fridges = [
            ...snapshot.docs.map((doc) => {...doc.data(), 'id': doc.id}),
            ...sharedSnapshot.docs
                .map((doc) => {...doc.data(), 'id': doc.id})
                .where((fridge) => !snapshot.docs.any((doc) => doc.id == fridge['id'])),
          ];
          _selectedFridgeId = _fridges.isNotEmpty ? _fridges[0]['id'] : null;
          _selectedFridgeName = _fridges.isNotEmpty ? _fridges[0]['name'] : '';
        });
        print('Fetched ${_fridges.length} fridges: ${_fridges.map((e) => e['name']).join(", ")}');
      }
    } catch (e) {
      print('Error fetching fridges: $e');
      if (mounted) _showErrorSnackBar('Lỗi khi tải danh sách tủ lạnh: $e');
    }
  }

  Future<void> _fetchStorageLogs({int page = 0}) async {
    setState(() => _isLoading = true);
    try {
      String url = '${Config.getNgrokUrl()}/search_storage_logs?userId=${widget.uid}&page=$page&limit=$_pageSize';
      if (_selectedFridgeId != null) url += '&fridgeId=${Uri.encodeComponent(_selectedFridgeId!)}';
      if (_selectedAreaId != null) url += '&areaId=${Uri.encodeComponent(_selectedAreaId!)}';
      if (_searchQuery.isNotEmpty) url += '&query=${Uri.encodeComponent(_searchQuery)}';
      String sortBy = _getSortParameter();
      if (sortBy.isNotEmpty) url += '&sortBy=$sortBy';
      print('Fetching storage logs: $url');
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
      );
      print('Response status: ${response.statusCode}, body: ${response.body}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final logs = List<Map<String, dynamic>>.from(data['logs'] ?? []).map((log) {
          DateTime? expiryDate = log['expiryDate'] is Timestamp
              ? (log['expiryDate'] as Timestamp).toDate().toLocal()
              : _parseDateTime(log['expiryDate'] as String?);
          DateTime? storageDate = log['storageDate'] is Timestamp
              ? (log['storageDate'] as Timestamp).toDate().toLocal()
              : _parseDateTime(log['storageDate'] as String?);
          return {
            ...log,
            'expiryDate': expiryDate,
            'storageDate': storageDate,
            'status': _getStatus(expiryDate),
          };
        }).toList();
        print('Fetched ${logs.length} storage logs');
        if (mounted) {
          setState(() {
            if (page == 0) {
              _storageLogs = logs;
            } else {
              _storageLogs.addAll(logs.where((newLog) => !_storageLogs.any((existingLog) => existingLog['id'] == newLog['id'])));
            }
            _isLoading = false;
          });
          await _checkAndNotifyExpiringItems();
        }
      } else {
        throw Exception('Failed to fetch storage logs: ${response.body}');
      }
    } catch (e) {
      print('Error fetching storage logs: $e');
      if (mounted) {
        setState(() {
          if (page == 0) _storageLogs = [];
          _isLoading = false;
        });
        _showErrorSnackBar('Lỗi khi tải danh sách thực phẩm: $e');
      }
    }
  }

  Future<void> _showFridgeManagementDialog() async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.kitchen_rounded, color: primaryColor),
            const SizedBox(width: 8),
            const Text('Quản lý tủ lạnh'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Danh sách tủ lạnh',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: currentTextPrimaryColor,
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: () async {
                      Navigator.pop(context);
                      await _showAddFridgeDialog();
                    },
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Thêm'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      minimumSize: Size.zero,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_fridges.isEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'Chưa có tủ lạnh nào',
                    style: TextStyle(color: currentTextSecondaryColor),
                  ),
                )
              else
                ListView.builder(
                  shrinkWrap: true,
                  itemCount: _fridges.length,
                  itemBuilder: (context, index) {
                    final fridge = _fridges[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: currentSurfaceColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _selectedFridgeId == fridge['id']
                              ? primaryColor
                              : Colors.grey.withOpacity(0.3),
                        ),
                      ),
                      child: ListTile(
                        leading: Icon(
                          Icons.kitchen_rounded,
                          color: _selectedFridgeId == fridge['id']
                              ? primaryColor
                              : currentTextSecondaryColor,
                        ),
                        title: Text(
                          fridge['name'],
                          style: TextStyle(
                            color: currentTextPrimaryColor,
                            fontWeight: _selectedFridgeId == fridge['id']
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(Icons.edit, color: primaryColor, size: 20),
                              onPressed: () => _showEditFridgeDialog(fridge),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete, color: errorColor, size: 20),
                              onPressed: () => _showDeleteFridgeDialog(fridge),
                            ),
                          ],
                        ),
                        onTap: () {
                          _selectFridge(fridge['id'], fridge['name']);
                          Navigator.pop(context);
                        },
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Đóng', style: TextStyle(color: currentTextSecondaryColor)),
          ),
        ],
      ),
    );
  }
  Future<void> _showDeleteFridgeDialog(Map<String, dynamic> fridge) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.warning_rounded, color: warningColor),
            const SizedBox(width: 8),
            const Text('Xác nhận xóa'),
          ],
        ),
        content: Text('Bạn có chắc chắn muốn xóa tủ lạnh "${fridge['name']}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Hủy', style: TextStyle(color: currentTextSecondaryColor)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: errorColor),
            child: const Text('Xóa', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _deleteFridge(fridge['id']);
    }
  }
  Future<void> _updateFridge(String fridgeId, String newName) async {
    try {
      final url = Uri.parse('${Config.getNgrokUrl()}/update_fridge/$fridgeId');
      final response = await http.put(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({
          'userId': widget.uid,
          'name': newName,
        }),
      );
      if (response.statusCode == 200) {
        _showSuccessSnackBar('Đã cập nhật tên tủ lạnh thành công!');
        await _fetchFridges(); // Làm mới danh sách tủ lạnh
      } else {
        final data = jsonDecode(response.body);
        _showErrorSnackBar('Lỗi khi cập nhật tủ lạnh: ${data['error'] ?? 'Không xác định'}');
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi khi cập nhật tủ lạnh: $e');
    }
  }
  Future<void> _deleteFridge(String fridgeId) async {
    try {
      final url = Uri.parse('${Config.getNgrokUrl()}/delete_fridge/$fridgeId?userId=${Uri.encodeComponent(widget.uid)}');
      final response = await http.delete(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
      );
      if (response.statusCode == 200) {
        _showSuccessSnackBar('Đã xóa tủ lạnh thành công!');
        await _fetchFridges(); // Làm mới danh sách tủ lạnh
      } else {
        final data = jsonDecode(response.body);
        _showErrorSnackBar('Lỗi khi xóa tủ lạnh: ${data['error'] ?? 'Không xác định'}');
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi khi xóa tủ lạnh: $e');
    }
  }
  Future<void> _showAreaManagementDialog() async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.add_location_alt_rounded, color: primaryColor),
            const SizedBox(width: 8),
            const Text('Quản lý khu vực'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Danh sách khu vực',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: currentTextPrimaryColor,
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: () async {
                      Navigator.pop(context);
                      await _showAddAreaDialog();
                    },
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Thêm'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      minimumSize: Size.zero,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_storageAreas.isEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'Chưa có khu vực nào',
                    style: TextStyle(color: currentTextSecondaryColor),
                  ),
                )
              else
                ListView.builder(
                  shrinkWrap: true,
                  itemCount: _storageAreas.length,
                  itemBuilder: (context, index) {
                    final area = _storageAreas[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: currentSurfaceColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _selectedAreaId == area['id']
                              ? primaryColor
                              : Colors.grey.withOpacity(0.3),
                        ),
                      ),
                      child: ListTile(
                        leading: Icon(
                          getIconForArea(area['name']),
                          color: _selectedAreaId == area['id']
                              ? primaryColor
                              : currentTextSecondaryColor,
                        ),
                        title: Text(
                          area['name'],
                          style: TextStyle(
                            color: currentTextPrimaryColor,
                            fontWeight: _selectedAreaId == area['id']
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(Icons.edit, color: primaryColor, size: 20),
                              onPressed: () => _showEditAreaDialog(area),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete, color: errorColor, size: 20),
                              onPressed: () => _showDeleteAreaDialog(area),
                            ),
                          ],
                        ),
                        onTap: () {
                          _selectArea(area['id'], area['name']);
                          Navigator.pop(context);
                        },
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Đóng', style: TextStyle(color: currentTextSecondaryColor)),
          ),
        ],
      ),
    );
  }

  Future<List<Map<String, dynamic>>> _fetchFridgeUsers(String fridgeId) async {
    try {
      final url = Uri.parse('${Config.getNgrokUrl()}/fridges/$fridgeId/get_users?userId=${Uri.encodeComponent(widget.uid)}');
      final response = await http.get(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final users = List<Map<String, dynamic>>.from(data['users'] ?? []);
        return users;
      } else {
        throw Exception('Failed to fetch fridge users: ${response.body}');
      }
    } catch (e) {
      print('Error fetching fridge users: $e');
      _showErrorSnackBar('Lỗi khi tải danh sách người dùng: $e');
      return [];
    }
  }
  Future<void> _removeUserFromFridge(String fridgeId, String userIdToRemove) async {
    try {
      final response = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/fridges/$fridgeId/remove_user'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({
          'ownerId': widget.uid,
          'userId': userIdToRemove,
        }),
      );
      final data = jsonDecode(response.body);
      if (response.statusCode == 200) {
        _showSuccessSnackBar('Đã xóa người dùng khỏi tủ lạnh!');
      } else {
        _showErrorSnackBar('Lỗi khi xóa người dùng: ${data['error'] ?? 'Không xác định'}');
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi khi xóa người dùng: $e');
    }
  }

  Future<void> _showFridgeUsersDialog() async {
    if (_selectedFridgeId == null) {
      _showErrorSnackBar('Vui lòng chọn một tủ lạnh trước.');
      return;
    }
    final users = await _fetchFridgeUsers(_selectedFridgeId!);
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.group_rounded, color: primaryColor),
            const SizedBox(width: 8),
            const Text('Quản lý người dùng'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Người dùng của $_selectedFridgeName',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: currentTextPrimaryColor,
                ),
              ),
              const SizedBox(height: 12),
              if (users.isEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'Chưa có người dùng nào',
                    style: TextStyle(color: currentTextSecondaryColor),
                  ),
                )
              else
                ListView.builder(
                  shrinkWrap: true,
                  itemCount: users.length,
                  itemBuilder: (context, index) {
                    final user = users[index];
                    final isOwner = user['role'] == 'owner';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: currentSurfaceColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isOwner ? primaryColor : Colors.grey.withOpacity(0.3),
                        ),
                      ),
                      child: ListTile(
                        leading: Icon(
                          isOwner ? Icons.person : Icons.person_outline,
                          color: isOwner ? primaryColor : currentTextSecondaryColor,
                        ),
                        title: Text(
                          user['name'] ?? 'Unknown',
                          style: TextStyle(
                            color: currentTextPrimaryColor,
                            fontWeight: isOwner ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          isOwner ? 'Chủ sở hữu' : 'Người được chia sẻ',
                          style: TextStyle(color: currentTextSecondaryColor),
                        ),
                        trailing: !isOwner
                            ? IconButton(
                          icon: Icon(Icons.delete, color: errorColor, size: 20),
                          onPressed: () => _showDeleteUserDialog(user['uid'], user['name'] ?? 'Unknown'),
                        )
                            : null,
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Đóng', style: TextStyle(color: currentTextSecondaryColor)),
          ),
        ],
      ),
    );
  }
  Future<void> _showDeleteUserDialog(String userId, String email) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.warning_rounded, color: warningColor),
            const SizedBox(width: 8),
            const Text('Xác nhận xóa'),
          ],
        ),
        content: Text('Bạn có chắc chắn muốn xóa "$email" khỏi tủ lạnh "$_selectedFridgeName"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Hủy', style: TextStyle(color: currentTextSecondaryColor)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: errorColor),
            child: const Text('Xóa', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _removeUserFromFridge(_selectedFridgeId!, userId);
    }
  }

  Future<void> _showEditFridgeDialog(Map<String, dynamic> fridge) async {
    final controller = TextEditingController(text: fridge['name']);
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Chỉnh sửa tủ lạnh'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Nhập tên tủ lạnh',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Hủy', style: TextStyle(color: currentTextSecondaryColor)),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;

              try {
                final response = await http.put(
                  Uri.parse('${Config.getNgrokUrl()}/update_fridge/${fridge['id']}'),
                  headers: {
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer ${widget.token}',
                  },
                  body: jsonEncode({'name': name}),
                );

                if (response.statusCode == 200) {
                  await _fetchFridges();
                  if (_selectedFridgeId == fridge['id']) {
                    setState(() => _selectedFridgeName = name);
                  }
                  _showSuccessSnackBar('Đã cập nhật tủ lạnh thành công!');
                  Navigator.pop(context);
                } else {
                  _showErrorSnackBar('Lỗi khi cập nhật tủ lạnh');
                }
              } catch (e) {
                _showErrorSnackBar('Lỗi khi cập nhật tủ lạnh: $e');
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: primaryColor),
            child: const Text('Lưu', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditAreaDialog(Map<String, dynamic> area) async {
    final controller = TextEditingController(text: area['name']);
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Chỉnh sửa khu vực'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Nhập tên khu vực',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Hủy', style: TextStyle(color: currentTextSecondaryColor)),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;

              try {
                final response = await http.put(
                  Uri.parse('${Config.getNgrokUrl()}/update_area/${area['id']}?userId=${Uri.encodeComponent(widget.uid)}'),
                  headers: {
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer ${widget.token}',
                  },
                  body: jsonEncode({'name': name}),
                );

                if (response.statusCode == 200) {
                  await _fetchStorageAreas();
                  if (_selectedAreaId == area['id']) {
                    setState(() => _selectedAreaName = name);
                  }
                  _showSuccessSnackBar('Đã cập nhật khu vực thành công!');
                  Navigator.pop(context);
                } else {
                  _showErrorSnackBar('Lỗi khi cập nhật khu vực: ${response.body}');
                }
              } catch (e) {
                _showErrorSnackBar('Lỗi khi cập nhật khu vực: $e');
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: primaryColor),
            child: const Text('Lưu', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _showDeleteAreaDialog(Map<String, dynamic> area) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.warning_rounded, color: warningColor),
            const SizedBox(width: 8),
            const Text('Xác nhận xóa'),
          ],
        ),
        content: Text('Bạn có chắc chắn muốn xóa khu vực "${area['name']}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Hủy', style: TextStyle(color: currentTextSecondaryColor)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: errorColor),
            child: const Text('Xóa', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final response = await http.delete(
          Uri.parse('${Config.getNgrokUrl()}/delete_area/${area['id']}?userId=${Uri.encodeComponent(widget.uid)}'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${widget.token}',
          },
        );

        if (response.statusCode == 200) {
          await _fetchStorageAreas();
          if (_selectedAreaId == area['id']) {
            setState(() {
              _selectedAreaId = null;
              _selectedAreaName = 'Tất cả';
            });
            await _fetchStorageLogs(page: 0);
          }
          _showSuccessSnackBar('Đã xóa khu vực thành công!');
        } else {
          _showErrorSnackBar('Lỗi khi xóa khu vực: ${response.body}');
        }
      } catch (e) {
        _showErrorSnackBar('Lỗi khi xóa khu vực: $e');
      }
    }
  }
  Future<void> _showAddFridgeDialog() async {
    final controller = TextEditingController();
    bool? result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.kitchen_rounded, color: primaryColor),
            const SizedBox(width: 8),
            const Text('Thêm tủ lạnh mới'),
          ],
        ),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Nhập tên tủ lạnh',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: primaryColor, width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_fridges.isEmpty ? false : true),
            child: Text(
              'Hủy',
              style: TextStyle(color: currentTextSecondaryColor),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) {
                _showErrorSnackBar('Vui lòng nhập tên tủ lạnh');
                return;
              }
              try {
                final response = await http.post(
                  Uri.parse('${Config.getNgrokUrl()}/add_fridge'),
                  headers: {
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer ${widget.token}',
                  },
                  body: jsonEncode({'name': name, 'ownerId': widget.uid}),
                );
                final data = jsonDecode(response.body);
                if (response.statusCode == 200) {
                  await _fetchFridges();
                  if (mounted) {
                    setState(() {
                      _selectedFridgeId = data['fridgeId'];
                      _selectedFridgeName = name;
                    });
                    _showSuccessSnackBar('Đã thêm tủ lạnh thành công!');
                    Navigator.of(context).pop(true);
                  }
                } else {
                  _showErrorSnackBar('Lỗi khi thêm tủ lạnh: ${data['error'] ?? 'Không xác định'}');
                }
              } catch (e) {
                _showErrorSnackBar('Lỗi khi thêm tủ lạnh: $e');
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Lưu', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (result == false && mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _showAddAreaDialog() async {
    if (_selectedFridgeId == null) {
      _showErrorSnackBar('Vui lòng chọn một tủ lạnh trước.');
      return;
    }
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.add_location_alt_rounded, color: primaryColor),
            const SizedBox(width: 8),
            const Text('Thêm khu vực mới'),
          ],
        ),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Nhập tên khu vực',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: primaryColor, width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Hủy',
              style: TextStyle(color: currentTextSecondaryColor),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) {
                _showErrorSnackBar('Vui lòng nhập tên khu vực');
                return;
              }
              try {
                final response = await http.post(
                  Uri.parse('${Config.getNgrokUrl()}/add_area'),
                  headers: {
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer ${widget.token}',
                  },
                  body: jsonEncode({
                    'name': name,
                    'fridgeId': _selectedFridgeId,
                    'userId': widget.uid,
                  }),
                );
                final data = jsonDecode(response.body);
                if (response.statusCode == 200) {
                  await _fetchStorageAreas();
                  _showSuccessSnackBar('Đã thêm khu vực thành công!');
                  Navigator.of(context).pop();
                } else {
                  _showErrorSnackBar('Lỗi khi thêm khu vực: ${data['error'] ?? 'Không xác định'}');
                }
              } catch (e) {
                _showErrorSnackBar('Lỗi khi thêm khu vực: $e');
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Lưu', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _showInviteUserDialog() async {
    if (_selectedFridgeId == null) {
      _showErrorSnackBar('Vui lòng chọn một tủ lạnh trước.');
      return;
    }
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.person_add_rounded, color: primaryColor),
            const SizedBox(width: 8),
            const Text('Mời người dùng'),
          ],
        ),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Nhập email người được mời',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: primaryColor, width: 2),
            ),
          ),
          keyboardType: TextInputType.emailAddress,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Hủy',
              style: TextStyle(color: currentTextSecondaryColor),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty || !RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(name)) {
                _showErrorSnackBar('Vui lòng nhập email hợp lệ');
                return;
              }
              try {
                final response = await http.post(
                  Uri.parse('${Config.getNgrokUrl()}/fridges/$_selectedFridgeId/send_invitation'),
                  headers: {
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer ${widget.token}',
                  },
                  body: jsonEncode({
                    'ownerId': widget.uid,
                    'inviteeEmail': name,
                  }),
                );
                final data = jsonDecode(response.body);
                if (response.statusCode == 200) {
                  _showSuccessSnackBar('Đã gửi lời mời thành công!');
                  Navigator.of(context).pop();
                } else {
                  _showErrorSnackBar('Lỗi khi gửi lời mời: ${data['error'] ?? 'Không xác định'}');
                }
              } catch (e) {
                _showErrorSnackBar('Lỗi khi gửi lời mời: $e');
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Gửi', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _acceptInvitation(String invitationId) async {
    try {
      final response = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/accept_invitation/$invitationId'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'userId': widget.uid}),
      );
      final data = jsonDecode(response.body);
      if (response.statusCode == 200) {
        await _fetchFridges();
        await _fetchPendingInvitations();
        setState(() {
          _selectedFridgeId = 'default_fridge_5989a234-9f75-40a8-8297-9c76128eb067';
          _selectedFridgeName = 'SamSung Smart';
        });
        await _fetchStorageAreas();
        await _fetchStorageLogs(page: 0);
        _showSuccessSnackBar('Đã chấp nhận lời mời!');
      } else {
        _showErrorSnackBar('Lỗi khi chấp nhận lời mời: ${data['error'] ?? 'Không xác định'}');
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi khi chấp nhận lời mời: $e');
    }
  }

  Future<void> _rejectInvitation(String invitationId) async {
    try {
      final response = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/reject_invitation/$invitationId'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({'userId': widget.uid}),
      );
      final data = jsonDecode(response.body);
      if (response.statusCode == 200) {
        await _fetchPendingInvitations();
        _showSuccessSnackBar('Đã từ chối lời mời!');
      } else {
        _showErrorSnackBar('Lỗi khi từ chối lời mời: ${data['error'] ?? 'Không xác định'}');
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi khi từ chối lời mời: $e');
    }
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.settings, color: primaryColor),
            const SizedBox(width: 8),
            const Text('Cài đặt'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.kitchen_rounded, color: primaryColor),
                title: const Text('Quản lý tủ lạnh'),
                onTap: () async {
                  Navigator.pop(context);
                  await _showFridgeManagementDialog();
                },
              ),
              ListTile(
                leading: Icon(Icons.add_location_alt_rounded, color: primaryColor),
                title: const Text('Quản lý khu vực'),
                onTap: () async {
                  Navigator.pop(context);
                  await _showAreaManagementDialog();
                },
              ),
              ListTile(
                leading: Icon(Icons.group_rounded, color: primaryColor),
                title: const Text('Quản lý người dùng'),
                onTap: () async {
                  Navigator.pop(context);
                  await _showFridgeUsersDialog();
                },
              ),
              ListTile(
                leading: Icon(Icons.person_add_rounded, color: primaryColor),
                title: const Text('Mời người dùng'),
                onTap: () async {
                  Navigator.pop(context);
                  await _showInviteUserDialog();
                },
              ),
              ListTile(
                leading: Icon(Icons.logout, color: errorColor),
                title: const Text('Đăng xuất'),
                onTap: () async {
                  Navigator.pop(context);
                  await _logout();
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Đóng', style: TextStyle(color: currentTextSecondaryColor)),
          ),
        ],
      ),
    );
  }
  void _selectFridge(String? fridgeId, String fridgeName) {
    setState(() {
      _selectedFridgeId = fridgeId;
      _selectedFridgeName = fridgeName;
      _currentPage = 0;
      _selectedAreaId = null;
      _selectedAreaName = 'Tất cả';
    });
    _fetchStorageAreas();
    _fetchStorageLogs(page: 0);
  }

  void _selectArea(String? areaId, String areaName) {
    setState(() {
      _selectedAreaId = areaId;
      _selectedAreaName = areaName;
      _currentPage = 0;
    });
    _fetchStorageLogs(page: 0);
  }

  void _toggleSearch() {
    setState(() {
      _isSearchVisible = !_isSearchVisible;
      if (!_isSearchVisible) {
        _searchController.clear();
        _searchQuery = '';
        _searchSuggestions.clear();
        _fetchStorageLogs(page: 0);
      }
    });
  }

  void _onSearchChanged(String query) {
    if (_searchDebounce?.isActive ?? false) _searchDebounce!.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted && _searchQuery == query) {
        setState(() {
          _searchQuery = query;
          _currentPage = 0;
        });
        _fetchStorageLogs(page: 0);
      }
    });
    setState(() {
      _searchQuery = query;
      if (query.isNotEmpty) {
        _updateSearchSuggestions(query);
      } else {
        _searchSuggestions.clear();
      }
    });
  }

  void _updateSearchSuggestions(String query) {
    final suggestions = _storageLogs
        .map((log) => log['foodName'] as String?)
        .where((name) => name != null && name.toLowerCase().contains(query.toLowerCase()))
        .take(5)
        .cast<String>()
        .toSet()
        .toList();
    setState(() => _searchSuggestions = suggestions);
  }

  void _selectSearchSuggestion(String suggestion) {
    _searchController.text = suggestion;
    _onSearchChanged(suggestion);
    setState(() => _searchSuggestions.clear());
    if (!_searchHistory.contains(suggestion)) {
      _searchHistory.insert(0, suggestion);
      if (_searchHistory.length > 10) _searchHistory.removeLast();
    }
  }

  void _toggleDarkMode() {
    setState(() => _isDarkMode = !_isDarkMode);
  }

  void _onSortChanged(SortOption? newSort) {
    if (newSort != null) {
      setState(() {
        _selectedSort = newSort;
        _currentPage = 0;
      });
      _fetchStorageLogs(page: 0);
    }
  }

  String _getSortDisplayName(SortOption option) {
    switch (option) {
      case SortOption.category:
        return 'Danh mục';
      case SortOption.expiryDate:
        return 'Hạn sử dụng';
      case SortOption.createdDate:
        return 'Ngày tạo';
      case SortOption.fresh:
        return 'Tươi';
      case SortOption.expiring:
        return 'Sắp hết hạn';
      case SortOption.expired:
        return 'Hết hạn';
      case SortOption.name:
        return 'Tên';
    }
  }

  IconData getIconForArea(String areaName) {
    switch (areaName.toLowerCase()) {
      case 'ngăn mát':
        return Icons.kitchen_outlined;
      case 'ngăn đá':
        return Icons.ac_unit_outlined;
      case 'ngăn cửa':
        return Icons.door_back_door;
      case 'kệ trên':
        return Icons.shelves;
      case 'kệ dưới':
        return Icons.inventory_2_outlined;
      default:
        return Icons.inventory_outlined;
    }
  }

  IconData _getFoodIcon(String foodName) {
    final name = foodName.toLowerCase();
    if (name.contains('thịt') || name.contains('gà') || name.contains('heo')) {
      return Icons.set_meal;
    } else if (name.contains('rau') || name.contains('củ')) {
      return Icons.eco;
    } else if (name.contains('trái') || name.contains('quả')) {
      return Icons.apple;
    } else if (name.contains('sữa') || name.contains('yaourt')) {
      return Icons.local_drink;
    }
    return Icons.fastfood;
  }

  int _getExpiringItemsCount(List<Map<String, dynamic>> logs) {
    final filteredLogs = _selectedAreaId == null
        ? logs
        : logs.where((log) => log['areaId'] == _selectedAreaId).toList();
    return filteredLogs.where((log) => log['status'] == 'expiring').length;
  }

  int _getExpiredItemsCount(List<Map<String, dynamic>> logs) {
    final filteredLogs = _selectedAreaId == null
        ? logs
        : logs.where((log) => log['areaId'] == _selectedAreaId).toList();
    return filteredLogs.where((log) => log['status'] == 'expired').length;
  }

  int _getTotalItemsCount(List<Map<String, dynamic>> logs) {
    return _selectedAreaId == null
        ? logs.length
        : logs.where((log) => log['areaId'] == _selectedAreaId).length;
  }

  void _showRecipeSuggestions(List<Map<String, dynamic>> storageLogs) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RecipeSuggestionScreen(
          foodItems: storageLogs,
          userId: widget.uid,
          isDarkMode: _isDarkMode,
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _filterStorageLogs(List<Map<String, dynamic>> logs) {
    final now = DateTime.now().toUtc().add(const Duration(hours: 7));
    switch (_selectedSort) {
      case SortOption.fresh:
        return logs.where((log) => log['status'] == 'fresh').toList();
      case SortOption.expiring:
        return logs.where((log) => log['status'] == 'expiring').toList();
      case SortOption.expired:
        return logs.where((log) => log['status'] == 'expired').toList();
      case SortOption.category:
      case SortOption.expiryDate:
      case SortOption.createdDate:
      case SortOption.name:
      default:
        return logs;
    }
  }

  void _showErrorSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.error_outline, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(child: Text(message)),
            ],
          ),
          backgroundColor: errorColor,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          margin: const EdgeInsets.all(16),
          action: SnackBarAction(
            label: 'Đóng',
            textColor: Colors.white,
            onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
          ),
        ),
      );
    }
  }

  void _showSuccessSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle_outline, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(child: Text(message)),
            ],
          ),
          backgroundColor: successColor,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          margin: const EdgeInsets.all(16),
        ),
      );
    }
  }

  Future<void> _deleteStorageLog(String logId) async {
    try {
      final response = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/delete_storage_log'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({
          'userId': widget.uid,
          'logId': logId,
        }),
      );
      final data = jsonDecode(response.body);
      if (response.statusCode == 200) {
        setState(() {
          _storageLogs.removeWhere((log) => log['id'] == logId);
        });
        _showSuccessSnackBar('Đã xóa thực phẩm thành công!');
      } else {
        _showErrorSnackBar('Lỗi khi xóa thực phẩm: ${data['error'] ?? 'Không xác định'}');
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi khi xóa thực phẩm: $e');
    }
  }

  Future<void> _deleteExpiredItems() async {
    if (_isDeletingExpired) return;
    final confirmed = await _showDeleteConfirmDialog();
    if (!confirmed) return;
    setState(() => _isDeletingExpired = true);
    try {
      final now = DateTime.now().toUtc().add(const Duration(hours: 7));
      final expiredItems = _storageLogs.where((log) {
        final expiryDate = log['expiryDate'] as DateTime?;
        return expiryDate != null && expiryDate.isBefore(now);
      }).toList();
      if (expiredItems.isEmpty) {
        _showSuccessSnackBar('Không có món nào đã hết hạn để xóa!');
        return;
      }
      int deletedCount = 0;
      for (var item in expiredItems) {
        final logId = item['id'] as String;
        try {
          final response = await http.post(
            Uri.parse('${Config.getNgrokUrl()}/delete_storage_log'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${widget.token}',
            },
            body: jsonEncode({
              'userId': widget.uid,
              'logId': logId,
            }),
          );
          final data = jsonDecode(response.body);
          if (response.statusCode == 200) {
            deletedCount++;
          } else {
            print('Error deleting storage log $logId: ${data['error'] ?? 'Unknown error'}');
          }
        } catch (e) {
          print('Error deleting storage log $logId: $e');
        }
      }
      await _fetchStorageLogs(page: 0);
      _showSuccessSnackBar('Đã xóa $deletedCount món hết hạn!');
    } catch (e) {
      print('Error deleting expired items: $e');
      _showErrorSnackBar('Lỗi khi xóa món hết hạn: $e');
    } finally {
      if (mounted) setState(() => _isDeletingExpired = false);
    }
  }

  Future<bool> _showDeleteConfirmDialog() async {
    return await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.warning_rounded, color: warningColor),
              const SizedBox(width: 8),
              const Text('Xác nhận xóa'),
            ],
          ),
          content: const Text('Bạn có chắc chắn muốn xóa tất cả món đã hết hạn không?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Hủy', style: TextStyle(color: currentTextSecondaryColor)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: errorColor,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Xóa', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    ) ?? false;
  }

  String _getSortParameter() {
    switch (_selectedSort) {
      case SortOption.category:
        return 'category';
      case SortOption.expiryDate:
        return 'expiryDate';
      case SortOption.createdDate:
        return 'createdDate';
      case SortOption.fresh:
        return 'fresh';
      case SortOption.expiring:
        return 'expiring';
      case SortOption.expired:
        return 'expired';
      case SortOption.name:
        return 'name';
      default:
        return 'category';
    }
  }

  Future<void> _checkAndNotifyExpiringItems() async {
    try {
      final now = DateTime.now().toUtc().add(const Duration(hours: 7));
      final expiringItems = _storageLogs.where((log) {
        if (log['expiryDate'] == null) return false;
        if (log['expiryDate'] is! DateTime) {
          print('Invalid expiryDate type for log ${log['id']}: ${log['expiryDate'].runtimeType}');
          return false;
        }
        final status = log['status'] as String;
        return (status == 'expiring' || status == 'expired') && !_notifiedLogs.contains(log['id']);
      }).toList();
      for (var item in expiringItems) {
        final logId = item['id'] as String;
        final foodName = item['foodName'] as String? ?? 'Unknown Food';
        final expiryDate = item['expiryDate'] as DateTime?;
        final title = item['status'] == 'expiring' ? 'Thực phẩm sắp hết hạn' : 'Thực phẩm đã hết hạn';
        await _showNotification(
          title,
          '$foodName ${item['status'] == 'expiring' ? 'sẽ hết hạn vào' : 'đã hết hạn vào'} ${expiryDate != null ? _dateFormat.format(expiryDate) : _dateFormat.format(now)}!',
          logId.hashCode,
          logId,
        );
        _notifiedLogs.add(logId);
      }
    } catch (e) {
      print('Error checking expiring items: $e');
    }
  }

  Future<void> _showNotification(String title, String body, int id, String storageLogId) async {
    try {
      const androidDetails = AndroidNotificationDetails(
        'food_expiry_channel',
        'Food Expiry Notifications',
        channelDescription: 'Thông báo về thực phẩm sắp hết hạn hoặc đã hết hạn',
        importance: Importance.max,
        priority: Priority.high,
        showWhen: true,
        icon: '@mipmap/ic_launcher',
      );
      const notificationDetails = NotificationDetails(android: androidDetails);
      await _notificationsPlugin.show(
        id,
        title,
        body,
        notificationDetails,
        payload: 'view_details_$storageLogId',
      );
    } catch (e) {
      print('Error showing notification: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isTablet = screenWidth > 600;
    List<Map<String, dynamic>> filteredStorageLogs = _filterStorageLogs(_storageLogs);
    final totalCount = _getTotalItemsCount(_storageLogs);
    final expiringCount = _getExpiringItemsCount(_storageLogs);
    final expiredCount = _getExpiredItemsCount(_storageLogs);
    return Scaffold(
      backgroundColor: currentBackgroundColor,
      body: SafeArea(
        child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: _fetchInitialData,
              color: primaryColor,
              backgroundColor: currentSurfaceColor,
              child: CustomScrollView(
                controller: _scrollController,
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: AnimatedBuilder(
                      animation: _fadeAnimation,
                      builder: (context, child) {
                        return Opacity(
                          opacity: _fadeAnimation.value,
                          child: _buildEnhancedHeader(totalCount, expiringCount, expiredCount, isTablet),
                        );
                      },
                    ),
                  ),
                  if (_isSearchVisible)
                    SliverToBoxAdapter(
                      child: _buildSmartSearchBar(),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),
                  if (_pendingInvitations.isNotEmpty)
                    SliverToBoxAdapter(
                      child: _buildPendingInvitations(),
                    ),
                  SliverToBoxAdapter(
                    child: _buildFridgeSection(),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),
                  SliverToBoxAdapter(
                    child: _buildAreaSection(),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  SliverToBoxAdapter(
                    child: _buildQuickActionsSection(),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  if (expiringCount > 0 || expiredCount > 0)
                    SliverToBoxAdapter(
                      child: _buildAlertSection(expiringCount, expiredCount),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  SliverToBoxAdapter(
                    child: _buildSortSection(),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  SliverToBoxAdapter(
                    child: _buildFoodListHeader(filteredStorageLogs),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  filteredStorageLogs.isEmpty
                      ? SliverFillRemaining(
                    child: SingleChildScrollView(
                      child: _buildEmptyState(),
                    ),
                  )
                      : _buildAdaptiveFoodList(filteredStorageLogs, isTablet),
                  const SliverToBoxAdapter(child: SizedBox(height: 100)),
                ],
              ),
            ),
            if (_isLoading)
              _buildLoadingOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildEnhancedHeader(int totalCount, int expiringCount, int expiredCount, bool isTablet) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: _isDarkMode
              ? [darkSurfaceColor, darkSurfaceColor.withOpacity(0.8)]
              : [Colors.white, const Color(0xFFF8FAFC)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _isDarkMode
                ? Colors.black.withOpacity(0.3)
                : primaryColor.withOpacity(0.1),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [primaryColor, secondaryColor],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: primaryColor.withOpacity(0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.kitchen_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'SmartFri',
                              style: TextStyle(
                                fontSize: isTablet ? 24 : 20,
                                fontWeight: FontWeight.bold,
                                color: currentTextPrimaryColor,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              _selectedFridgeName.isNotEmpty ? _selectedFridgeName : 'Chọn tủ lạnh',
                              style: TextStyle(
                                fontSize: isTablet ? 16 : 14,
                                color: currentTextSecondaryColor,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHeaderIconButton(
                      _isSearchVisible ? Icons.close : Icons.search,
                      _toggleSearch,
                      primaryColor,
                    ),
                    const SizedBox(width: 8),
                    _buildHeaderIconButton(
                      _isDarkMode ? Icons.light_mode : Icons.dark_mode,
                      _toggleDarkMode,
                      warningColor,
                    ),
                    const SizedBox(width: 8),
                    _buildHeaderIconButton(
                      Icons.settings,
                      _showSettingsDialog,
                      secondaryColor,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _buildQuickStat('$totalCount', 'Tổng', Icons.inventory_2_rounded, primaryColor)),
                const SizedBox(width: 8),
                Expanded(child: _buildQuickStat('$expiringCount', 'Sắp hết', Icons.warning_rounded, warningColor)),
                const SizedBox(width: 8),
                Expanded(child: _buildQuickStat('$expiredCount', 'Hết hạn', Icons.error_rounded, errorColor)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderIconButton(IconData icon, VoidCallback onPressed, Color color) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: IconButton(
        icon: Icon(icon, color: color, size: 20),
        onPressed: onPressed,
        padding: EdgeInsets.zero,
      ),
    );
  }

  Widget _buildSmartSearchBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: currentSurfaceColor,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(_isDarkMode ? 0.2 : 0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              style: TextStyle(color: currentTextPrimaryColor),
              decoration: InputDecoration(
                hintText: 'Tìm kiếm thực phẩm...',
                hintStyle: TextStyle(color: currentTextSecondaryColor),
                prefixIcon: Icon(Icons.search, color: primaryColor),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                  icon: Icon(Icons.clear, color: currentTextSecondaryColor),
                  onPressed: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                )
                    : null,
                filled: true,
                fillColor: Colors.transparent,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingInvitations() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Lời mời tham gia',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: currentTextPrimaryColor,
            ),
          ),
          const SizedBox(height: 12),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _pendingInvitations.length,
            itemBuilder: (context, index) {
              final invitation = _pendingInvitations[index];
              final fridgeName = invitation['fridgeName'] ?? 'Unknown Fridge';
              final inviterId = invitation['inviterId'] ?? 'Unknown';
              final invitationId = invitation['id'] ?? '';
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: currentSurfaceColor,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(_isDarkMode ? 0.2 : 0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: primaryColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.mail_outline, color: primaryColor),
                  ),
                  title: Text(
                    'Mời tham gia $fridgeName',
                    style: TextStyle(
                      color: currentTextPrimaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    'Từ: $inviterId',
                    style: TextStyle(color: currentTextSecondaryColor),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: successColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: IconButton(
                          icon: Icon(Icons.check, color: successColor),
                          onPressed: () => _acceptInvitation(invitationId),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        decoration: BoxDecoration(
                          color: errorColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: IconButton(
                          icon: Icon(Icons.close, color: errorColor),
                          onPressed: () => _rejectInvitation(invitationId),
                        ),
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

  Widget _buildFridgeSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tủ lạnh',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: currentTextPrimaryColor,
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ..._fridges.map((fridge) => Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _buildModernFridgeFilter(
                    fridge['id'] as String?,
                    fridge['name'] as String,
                    Icons.kitchen_rounded,
                  ),
                )),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _buildAddButton('Quản lý', _showFridgeManagementDialog),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAreaSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Khu vực',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: currentTextPrimaryColor,
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _buildModernAreaFilter(null, 'Tất cả', Icons.apps_rounded),
                ),
                ..._storageAreas.map((area) => Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _buildModernAreaFilter(
                    area['id'] as String?,
                    area['name'] as String,
                    getIconForArea(area['name'] as String),
                  ),
                )),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _buildAddButton('Quản lý', _showAreaManagementDialog),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActionsSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Thao tác nhanh',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: currentTextPrimaryColor,
            ),
          ),
          const SizedBox(height: 16),
          _buildEnhancedActionGrid(),
        ],
      ),
    );
  }

  Widget _buildAlertSection(int expiringCount, int expiredCount) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          if (expiringCount > 0)
            _buildEnhancedAlertCard(
              '$expiringCount món sắp hết hạn!',
              'Hãy sử dụng sớm để tránh lãng phí',
              Icons.access_time_rounded,
              _isDarkMode ? warningColor.withOpacity(0.2) : const Color(0xFFFFF8E1),
              warningColor,
              null,
            ),
          if (expiredCount > 0)
            Padding(
              padding: EdgeInsets.only(top: expiringCount > 0 ? 12 : 0),
              child: _buildEnhancedAlertCard(
                '$expiredCount món đã hết hạn!',
                'Cần xử lý ngay để đảm bảo an toàn',
                Icons.warning_rounded,
                _isDarkMode ? errorColor.withOpacity(0.2) : const Color(0xFFFFEBEE),
                errorColor,
                _deleteExpiredItems,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSortSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sắp xếp theo',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: currentTextPrimaryColor,
            ),
          ),
          const SizedBox(height: 12),
          _buildSortOptions(),
        ],
      ),
    );
  }

  Widget _buildFoodListHeader(List<Map<String, dynamic>> filteredStorageLogs) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              _selectedFridgeName.isEmpty ? 'Không có tủ lạnh' : _selectedFridgeName,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: currentTextPrimaryColor,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [primaryColor, secondaryColor],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${filteredStorageLogs.length} món',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEnhancedActionGrid() {
    return Container(
      decoration: BoxDecoration(
        color: currentSurfaceColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(_isDarkMode ? 0.2 : 0.1),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildCompactActionButton(
                  'Thêm thực phẩm',
                  Icons.add_rounded,
                  addFoodColor,
                      () {
                    if (_selectedFridgeId == null) {
                      _showErrorSnackBar('Vui lòng chọn hoặc thêm một tủ lạnh trước.');
                      return;
                    }
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => AddFoodScreen(
                          uid: widget.uid,
                          token: widget.token,
                          isDarkMode: _isDarkMode,
                          fridgeId: _selectedFridgeId!,
                        ),
                      ),
                    ).then((value) async {
                      if (value == true) await _fetchStorageLogs(page: 0);
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildCompactActionButton(
                  'Gợi ý món ăn',
                  Icons.restaurant_menu_rounded,
                  recipeColor,
                      () => _showRecipeSuggestions(_storageLogs),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildCompactActionButton(
                  'Danh sách mua',
                  Icons.shopping_cart_rounded,
                  shoppingColor,
                      () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => CartScreen(userId: widget.uid, isDarkMode: _isDarkMode),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildCompactActionButton(
                  'Kế hoạch ăn',
                  Icons.calendar_month_rounded,
                  mealPlanColor,
                      () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => MealPlanScreen(
                          userId: widget.uid,
                          isDarkMode: _isDarkMode,
                          fridgeId: _selectedFridgeId,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCompactActionButton(String title, IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [color.withOpacity(0.1), color.withOpacity(0.05)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: color.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [color, color.withOpacity(0.8)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: color.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(
                icon,
                color: Colors.white,
                size: 24,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: currentTextPrimaryColor,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShimmerActionGrid(int crossAxisCount) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: crossAxisCount,
      childAspectRatio: 1.2,
      mainAxisSpacing: 16,
      crossAxisSpacing: 16,
      children: List.generate(4, (index) => _buildShimmerActionCard()),
    );
  }

  Widget _buildShimmerActionCard() {
    return Shimmer.fromColors(
      baseColor: _isDarkMode ? Colors.grey[800]! : Colors.grey[300]!,
      highlightColor: _isDarkMode ? Colors.grey[700]! : Colors.grey[100]!,
      child: Container(
        decoration: BoxDecoration(
          color: currentSurfaceColor,
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }

  Widget _buildSortOptions() {
    return _isLoading
        ? _buildShimmerSortOptions()
        : SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: SortOption.values.map((option) {
          bool isSelected = _selectedSort == option;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Container(
              decoration: BoxDecoration(
                gradient: isSelected
                    ? LinearGradient(
                  colors: [primaryColor, secondaryColor],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
                    : null,
                color: isSelected ? null : currentSurfaceColor,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(_isDarkMode ? 0.2 : 0.1),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _onSortChanged(option),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      _getSortDisplayName(option),
                      style: TextStyle(
                        color: isSelected ? Colors.white : currentTextPrimaryColor,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildShimmerSortOptions() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(
          5,
              (index) => Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Shimmer.fromColors(
              baseColor: _isDarkMode ? Colors.grey[800]! : Colors.grey[300]!,
              highlightColor: _isDarkMode ? Colors.grey[700]! : Colors.grey[100]!,
              child: Container(
                width: 80,
                height: 36,
                decoration: BoxDecoration(
                  color: currentSurfaceColor,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModernFridgeFilter(String? fridgeId, String name, IconData icon) {
    final bool isSelected = _selectedFridgeId == fridgeId;
    return GestureDetector(
      onTap: () => _selectFridge(fridgeId, name),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          gradient: isSelected
              ? LinearGradient(
            colors: [primaryColor, secondaryColor],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
              : null,
          color: isSelected ? null : currentSurfaceColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(_isDarkMode ? 0.2 : 0.1),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isSelected ? Colors.white : currentTextSecondaryColor,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              name,
              style: TextStyle(
                color: isSelected ? Colors.white : currentTextPrimaryColor,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModernAreaFilter(String? areaId, String name, IconData icon) {
    final bool isSelected = _selectedAreaId == areaId;
    return GestureDetector(
      onTap: () => _selectArea(areaId, name),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          gradient: isSelected
              ? LinearGradient(
            colors: [primaryColor, secondaryColor],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
              : null,
          color: isSelected ? null : currentSurfaceColor,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(_isDarkMode ? 0.2 : 0.1),
              blurRadius: 6,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isSelected ? Colors.white : currentTextSecondaryColor,
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              name,
              style: TextStyle(
                color: isSelected ? Colors.white : currentTextPrimaryColor,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: primaryColor.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: primaryColor.withOpacity(0.3),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.settings, color: primaryColor, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: primaryColor,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickStat(String value, String label, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: currentTextPrimaryColor,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: currentTextSecondaryColor,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildEnhancedAlertCard(
      String title,
      String subtitle,
      IconData icon,
      Color backgroundColor,
      Color iconColor,
      VoidCallback? onTap,
      ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: iconColor.withOpacity(0.2),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: currentTextPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: currentTextSecondaryColor,
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              Icon(
                Icons.arrow_forward_ios,
                color: currentTextSecondaryColor,
                size: 16,
              ),
          ],
        ),
      ),
    );
  }

  SliverList _buildAdaptiveFoodList(List<Map<String, dynamic>> storageLogs, bool isTablet) {
    return SliverList(
      delegate: SliverChildBuilderDelegate(
            (context, index) {
          final log = storageLogs[index];
          final foodName = log['foodName'] as String? ?? 'Unknown Food';
          final quantity = log['quantity']?.toString() ?? '0';
          final unit = _units.firstWhere(
                (u) => u['id'] == log['unitId'],
            orElse: () => {'name': 'Unknown'},
          )['name'] as String;
          final expiryDate = log['expiryDate'] as DateTime?;
          final status = log['status'] as String? ?? 'unknown';
          final areaName = _storageAreas
              .firstWhere(
                (area) => area['id'] == log['areaId'],
            orElse: () => {'name': 'Unknown'},
          )['name'] as String;

          Color statusColor;
          switch (status) {
            case 'expired':
              statusColor = errorColor;
              break;
            case 'expiring':
              statusColor = warningColor;
              break;
            default:
              statusColor = successColor;
              break;
          }

          return FadeTransition(
            opacity: _fadeAnimation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: Offset(0, _slideAnimation.value / 100),
                end: Offset.zero,
              ).animate(_animationController),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Slidable(
                  key: ValueKey(log['id']),
                  startActionPane: ActionPane(
                    motion: const ScrollMotion(),
                    extentRatio: 0.3,
                    children: [
                      SlidableAction(
                        onPressed: (_) => _deleteStorageLog(log['id']),
                        backgroundColor: errorColor,
                        foregroundColor: Colors.white,
                        icon: Icons.delete,
                        label: 'Xóa',
                        borderRadius: BorderRadius.circular(12),
                        autoClose: true,
                      ),
                    ],
                  ),
                  endActionPane: ActionPane(
                    motion: const ScrollMotion(),
                    extentRatio: 0.3,
                    children: [
                      SlidableAction(
                        onPressed: (_) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => FoodDetailScreen(
                                storageLogId: log['id'],
                                userId: widget.uid,
                                initialLog: log,
                                isDarkMode: _isDarkMode,
                              ),
                            ),
                          ).then((value) async {
                            if (value is Map<String, dynamic> && value['refreshStorageLogs'] == true) {
                              await _fetchStorageLogs(page: 0);
                            }
                          });
                        },
                        backgroundColor: primaryColor,
                        foregroundColor: Colors.white,
                        icon: Icons.info,
                        label: 'Chi tiết',
                        borderRadius: BorderRadius.circular(12),
                        autoClose: true,
                      ),
                    ],
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      color: currentSurfaceColor,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(_isDarkMode ? 0.2 : 0.1),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => FoodDetailScreen(
                                storageLogId: log['id'],
                                userId: widget.uid,
                                initialLog: log,
                                isDarkMode: _isDarkMode,
                              ),
                            ),
                          ).then((value) async {
                            if (value is Map<String, dynamic> && value['refreshStorageLogs'] == true) {
                              await _fetchStorageLogs(page: 0);
                            }
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: statusColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  _getFoodIcon(foodName),
                                  color: statusColor,
                                  size: 24,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      foodName,
                                      style: TextStyle(
                                        fontSize: isTablet ? 18 : 16,
                                        fontWeight: FontWeight.w600,
                                        color: currentTextPrimaryColor,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Số lượng: $quantity $unit',
                                      style: TextStyle(
                                        fontSize: isTablet ? 14 : 12,
                                        color: currentTextSecondaryColor,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'HSD: ${expiryDate != null ? _dateFormat.format(expiryDate) : 'Không rõ'}',
                                      style: TextStyle(
                                        fontSize: isTablet ? 14 : 12,
                                        color: statusColor,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Khu vực: $areaName',
                                      style: TextStyle(
                                        fontSize: isTablet ? 14 : 12,
                                        color: currentTextSecondaryColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.arrow_forward_ios,
                                color: currentTextSecondaryColor,
                                size: 16,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
        childCount: storageLogs.length,
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(
              Icons.kitchen_rounded,
              size: 80,
              color: primaryColor,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Không có thực phẩm nào!',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: currentTextPrimaryColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Hãy thêm thực phẩm để bắt đầu quản lý.',
            style: TextStyle(
              fontSize: 14,
              color: currentTextSecondaryColor,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [primaryColor, secondaryColor],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: primaryColor.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ElevatedButton.icon(
              onPressed: () {
                if (_selectedFridgeId == null) {
                  _showErrorSnackBar('Vui lòng chọn hoặc thêm một tủ lạnh trước.');
                  return;
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AddFoodScreen(
                      uid: widget.uid,
                      token: widget.token,
                      isDarkMode: _isDarkMode,
                      fridgeId: _selectedFridgeId!,
                    ),
                  ),
                ).then((value) async {
                  if (value == true) await _fetchStorageLogs(page: 0);
                });
              },
              icon: const Icon(Icons.add, size: 20, color: Colors.white),
              label: const Text('Thêm thực phẩm', style: TextStyle(color: Colors.white)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.3),
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: currentSurfaceColor,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [primaryColor, secondaryColor],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: const Center(
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    strokeWidth: 3.0,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Đang tải dữ liệu...',
                style: TextStyle(
                  color: currentTextPrimaryColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _logout() async {
    if (_isLoggingOut || !mounted) return;
    setState(() {
      _isLoggingOut = true;
    });
    try {
      await GoogleSignIn().signOut();
      await FirebaseAuth.instance.signOut();
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => const WelcomeScreen()),
              (Route<dynamic> route) => false,
        );
        _showSuccessSnackBar('Đã đăng xuất thành công!');
      }
    } catch (e) {
      print('Lỗi đăng xuất: $e');
      if (mounted) {
        _showErrorSnackBar('Lỗi đăng xuất: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoggingOut = false;
        });
      }
    }
  }

  void _onScroll() {
    // Không tải dữ liệu khi scroll
  }

  @override
  void dispose() {
    _animationController.dispose();
    _fabAnimationController.dispose();
    _shimmerController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }
}