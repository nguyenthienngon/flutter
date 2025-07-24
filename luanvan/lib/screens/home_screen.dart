import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:workmanager/workmanager.dart';
import 'dart:io' show Platform;
import 'package:permission_handler/permission_handler.dart';
import 'add_food_screen.dart';
import 'meal_plan.dart';
import 'recipe_suggestion_screen.dart';
import 'food_detail_screen.dart';
import 'cart_screen.dart';
import 'config.dart';

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
          'status': _getStatusStatic(expiryDate),
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
    String cleanedDateString = dateString.replaceAll(RegExp(r'\+00:00\+07:00$'), '+07:00');
    return DateTime.parse(cleanedDateString).toLocal();
  } catch (e) {
    print('Error parsing date "$dateString": $e');
    return null;
  }
}

String _getStatusStatic(DateTime? expiryDate) {
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
        id, title, body, notificationDetails,
        payload: 'view_details_$storageLogId'
    );
  } catch (e) {
    print('Error showing notification: $e');
  }
}

enum SortOption {
  category,
  expiryDate,
  createdDate,
  fresh,
  expiring,
  expired,
  name
}

class HomeScreen extends StatefulWidget {
  final String uid;
  final String token;

  const HomeScreen({super.key, required this.uid, required this.token});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final String _filter = 'Tất cả';
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  String? _selectedAreaId;
  String _selectedAreaName = 'Tất cả';
  late AnimationController _animationController;
  late AnimationController _fabAnimationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _slideAnimation;
  late FlutterLocalNotificationsPlugin _notificationsPlugin;
  bool _isLoading = true;
  bool _isDeletingExpired = false;
  bool _isDarkMode = false;
  bool _isSearchVisible = false;
  String _searchQuery = '';
  SortOption _selectedSort = SortOption.category;
  final TextEditingController _searchController = TextEditingController();
  int _displayedItems = 20;
  final ScrollController _scrollController = ScrollController();
  List<String> _searchSuggestions = [];
  final List<String> _searchHistory = [];
  final Color primaryColor = const Color(0xFF0078D7);
  final Color secondaryColor = const Color(0xFF50E3C2);
  final Color accentColor = const Color(0xFF00B294);
  final Color successColor = const Color(0xFF00C851);
  final Color warningColor = const Color(0xFFE67E22);
  final Color errorColor = const Color(0xFFE74C3C);
  final Color backgroundColor = const Color(0xFFE6F7FF);
  final Color surfaceColor = Colors.white;
  final Color textPrimaryColor = const Color(0xFF202124);
  final Color textSecondaryColor = const Color(0xFF5F6368);
  final Color darkBackgroundColor = const Color(0xFF121212);
  final Color darkSurfaceColor = const Color(0xFF1E1E1E);
  final Color darkTextPrimaryColor = const Color(0xFFE0E0E0);
  final Color darkTextSecondaryColor = const Color(0xFFB0B0B0);
  final Color addFoodColor = const Color(0xFF007AFF);
  final Color recipeColor = const Color(0xFF34C759);
  final Color shoppingColor = const Color(0xFFAF52DE);
  final Color cleanupColor = const Color(0xFFFF9500);
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
    setState(() => _isLoading = true);
    try {
      await Future.wait([
        _fetchStorageAreas(),
        _fetchStorageLogs(page: 0),
      ]);
    } catch (e) {
      print('Error fetching initial data: $e');
      if (mounted) _showErrorSnackBar('Lỗi khi tải dữ liệu: $e');
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
        if (mounted) setState(() => _storageAreas = areas);
      } else {
        throw Exception('Failed to fetch storage areas: ${response.body}');
      }
    } catch (e) {
      print('Error fetching storage areas: $e');
      if (mounted) {
        setState(() => _storageAreas = [
        {'id': '1', 'name': 'Ngăn mát'},
        {'id': '2', 'name': 'Ngăn đá'},
        {'id': '3', 'name': 'Ngăn cửa'},
        {'id': '4', 'name': 'Kệ trên'},
        {'id': '5', 'name': 'Kệ dưới'},
      ]);
      }
    }
  }

  Future<void> _fetchStorageLogs({int page = 0}) async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      String url = '${Config.getNgrokUrl()}/search_storage_logs?userId=${widget.uid}&page=$page&limit=$_pageSize';
      if (_selectedAreaId != null) url += '&areaId=$_selectedAreaId';
      if (_searchQuery.isNotEmpty) url += '&query=${Uri.encodeComponent(_searchQuery)}';
      String sortBy = _getSortParameter();
      if (sortBy.isNotEmpty) url += '&sortBy=$sortBy';

      final response = await http.get(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final logs = List<Map<String, dynamic>>.from(data['logs'] ?? []);
        final processedLogs = logs.map((log) {
          final expiryDateString = log['expiryDate'] as String?;
          final storageDateString = log['storageDate'] as String?;
          final foodId = log['foodId'] as String?;
          final foodName = foodId != null && _nameCache.containsKey('food_$foodId')
              ? _nameCache['food_$foodId']
              : log['foodName'] ?? 'Unknown Food';
          return {
            ...log,
            'foodName': foodName,
            'expiryDate': log['expiryDate'] is Timestamp
                ? (log['expiryDate'] as Timestamp).toDate().toLocal()
                : _parseDateTime(expiryDateString),
            'storageDate': log['storageDate'] is Timestamp
                ? (log['storageDate'] as Timestamp).toDate().toLocal()
                : _parseDateTime(storageDateString),
            'status': _getStatus(log['expiryDate'] is Timestamp
                ? (log['expiryDate'] as Timestamp).toDate().toLocal()
                : _parseDateTime(expiryDateString)),
          };
        }).toList();
        if (mounted) {
          setState(() {
            if (page == 0) {
              _storageLogs = processedLogs;
            } else {
              _storageLogs.addAll(processedLogs);
            }
            _isLoading = false;
            _displayedItems = (_pageSize * (page + 1)).clamp(0, _storageLogs.length);
            print('Updated _storageLogs: $processedLogs');
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
        _storageLogs = [];
        _isLoading = false;
      });
      }
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      if (_displayedItems < _storageLogs.length) {
        _currentPage++;
        _fetchStorageLogs(page: _currentPage);
      }
    }
  }

  String _getSortParameter() {
    switch (_selectedSort) {
      case SortOption.category: return 'category';
      case SortOption.expiryDate: return 'expiryDate';
      case SortOption.createdDate: return 'createdDate';
      case SortOption.fresh: return 'fresh';
      case SortOption.expiring: return 'expiring';
      case SortOption.expired: return 'expired';
      case SortOption.name: return 'name';
      default: return 'category';
    }
  }

  Future<void> _checkAndNotifyExpiringItems() async {
    try {
      final now = DateTime.now().toUtc().add(const Duration(hours: 7));
      final expiringItems = _storageLogs.where((log) {
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
          id, title, body, notificationDetails,
          payload: 'view_details_$storageLogId'
      );
    } catch (e) {
      print('Error showing notification: $e');
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
        final foodId = item['foodId'] as String?;
        if (foodId == null) {
          print('No foodId found for log $logId, skipping...');
          continue;
        }
        try {
          await _firestore.runTransaction((transaction) async {
            final foodRef = _firestore.collection('Foods').doc(foodId);
            final storageLogRef = _firestore.collection('StorageLogs').doc(logId);
            final foodDoc = await transaction.get(foodRef);
            final storageLogDoc = await transaction.get(storageLogRef);
            if (!foodDoc.exists || foodDoc['userId'] != widget.uid) throw Exception('Unauthorized or Food not found for log $logId');
            if (!storageLogDoc.exists || storageLogDoc['userId'] != widget.uid) throw Exception('Unauthorized or StorageLog not found for log $logId');
            transaction.delete(foodRef);
            transaction.delete(storageLogRef);
          });
          deletedCount++;
        } catch (e) {
          print('Error deleting item $logId: $e');
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
      case SortOption.category: return 'Danh mục';
      case SortOption.expiryDate: return 'Hạn sử dụng';
      case SortOption.createdDate: return 'Ngày tạo';
      case SortOption.fresh: return 'Tươi';
      case SortOption.expiring: return 'Sắp hết hạn';
      case SortOption.expired: return 'Hết hạn';
      case SortOption.name: return 'Tên';
    }
  }

  IconData getIconForArea(String areaName) {
    switch (areaName.toLowerCase()) {
      case 'ngăn mát': return Icons.kitchen_outlined;
      case 'ngăn đá': return Icons.ac_unit_outlined;
      case 'ngăn cửa': return Icons.door_back_door;
      case 'kệ trên': return Icons.shelves;
      case 'kệ dưới': return Icons.inventory_2_outlined;
      default: return Icons.inventory_outlined;
    }
  }

  IconData _getFoodIcon(String foodName) {
    final name = foodName.toLowerCase();
    if (name.contains('thịt') || name.contains('gà') || name.contains('heo')) {
      return Icons.set_meal;
    } else if (name.contains('rau') || name.contains('củ')) return Icons.eco;
    else if (name.contains('trái') || name.contains('quả')) return Icons.apple;
    else if (name.contains('sữa') || name.contains('yaourt')) return Icons.local_drink;
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
      case SortOption.fresh: return logs.where((log) => log['status'] == 'fresh').toList();
      case SortOption.expiring: return logs.where((log) => log['status'] == 'expiring').toList();
      case SortOption.expired: return logs.where((log) => log['status'] == 'expired').toList();
      case SortOption.category:
      case SortOption.expiryDate:
      case SortOption.createdDate:
      case SortOption.name:
      default: return logs;
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

  @override
  void dispose() {
    _animationController.dispose();
    _fabAnimationController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
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
                        return Transform.translate(
                          offset: const Offset(0, -20),
                          child: Opacity(
                            opacity: _fadeAnimation.value,
                            child: Container(
                              height: isTablet ? 200 : 180,
                              margin: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [primaryColor, accentColor],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderRadius: BorderRadius.circular(24),
                                boxShadow: [
                                  BoxShadow(
                                    color: primaryColor.withOpacity(0.4),
                                    blurRadius: 20,
                                    offset: const Offset(0, 10),
                                  ),
                                ],
                              ),
                              child: Stack(
                                children: [
                                  Positioned(
                                    right: -50,
                                    top: -50,
                                    child: Container(
                                      width: 150,
                                      height: 150,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.white.withOpacity(0.1),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    right: -20,
                                    bottom: -30,
                                    child: Container(
                                      width: 100,
                                      height: 100,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.white.withOpacity(0.05),
                                      ),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              flex: 3,
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    children: [
                                                      Container(
                                                        padding: const EdgeInsets.all(6),
                                                        decoration: BoxDecoration(
                                                          gradient: RadialGradient(
                                                            colors: [secondaryColor, Colors.white.withOpacity(0.3)],
                                                            radius: 0.8,
                                                          ),
                                                          shape: BoxShape.circle,
                                                          boxShadow: [
                                                            BoxShadow(
                                                              color: Colors.white.withOpacity(0.3),
                                                              blurRadius: 8,
                                                              offset: const Offset(0, 2),
                                                            ),
                                                          ],
                                                        ),
                                                        child: const Icon(
                                                          Icons.kitchen,
                                                          color: Colors.white,
                                                          size: 20,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      Flexible(
                                                        child: ShaderMask(
                                                          shaderCallback: (bounds) => LinearGradient(
                                                            colors: [Colors.white, secondaryColor],
                                                            begin: Alignment.topLeft,
                                                            end: Alignment.bottomRight,
                                                          ).createShader(bounds),
                                                          child: Text(
                                                            'SmartFri',
                                                            style: TextStyle(
                                                              fontSize: isTablet ? 28 : 24,
                                                              fontWeight: FontWeight.bold,
                                                              color: Colors.white,
                                                              letterSpacing: 0.5,
                                                            ),
                                                            overflow: TextOverflow.ellipsis,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    'Quản lý thông minh tủ lạnh',
                                                    style: TextStyle(
                                                      fontSize: isTablet ? 16 : 14,
                                                      color: Colors.white.withOpacity(0.9),
                                                      fontWeight: FontWeight.w500,
                                                    ),
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ),
                                            ),
                                            SizedBox(
                                              width: isTablet ? 140 : 120,
                                              child: Row(
                                                mainAxisAlignment: MainAxisAlignment.end,
                                                children: [
                                                  _buildCompactIconButton(
                                                    _isSearchVisible ? Icons.close : Icons.search,
                                                    _toggleSearch,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  _buildCompactIconButton(
                                                    _isDarkMode ? Icons.light_mode : Icons.dark_mode,
                                                    _toggleDarkMode,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  _buildCompactIconButton(
                                                    Icons.shopping_cart_outlined,
                                                        () {
                                                      Navigator.push(
                                                        context,
                                                        MaterialPageRoute(
                                                          builder: (context) => CartScreen(userId: widget.uid, isDarkMode: _isDarkMode),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        const Spacer(flex: 1),
                                        isTablet
                                            ? Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            _buildAnimatedQuickStat('$totalCount', 'Tổng số', Icons.inventory_2_rounded, 0),
                                            _buildAnimatedQuickStat('$expiringCount', 'Sắp hết hạn', Icons.warning_rounded, 1),
                                            _buildAnimatedQuickStat('$expiredCount', 'Hết hạn', Icons.error_rounded, 2),
                                          ],
                                        )
                                            : Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            _buildQuickStat('$totalCount', 'Tổng số', Icons.inventory_2_rounded),
                                            _buildQuickStat('$expiringCount', 'Sắp hết hạn', Icons.warning_rounded),
                                            _buildQuickStat('$expiredCount', 'Hết hạn', Icons.error_rounded),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (_isSearchVisible)
                    SliverToBoxAdapter(
                      child: _buildSmartSearchBar(),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),
                  SliverToBoxAdapter(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Khu vực',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: currentTextPrimaryColor,
                            ),
                          ),
                          const SizedBox(height: 8),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            child: Row(
                              children: [
                                _buildModernAreaFilter(null, 'Tất cả', Icons.apps_rounded),
                                ..._storageAreas.map((area) => _buildModernAreaFilter(
                                  area['id'] as String?,
                                  area['name'] as String,
                                  getIconForArea(area['name'] as String),
                                )),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  SliverToBoxAdapter(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Thao tác nhanh',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: currentTextPrimaryColor,
                            ),
                          ),
                          const SizedBox(height: 16),
                          _buildResponsiveActionGrid(),
                        ],
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  if (expiringCount > 0 || expiredCount > 0)
                    SliverToBoxAdapter(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          children: [
                            if (expiringCount > 0)
                              _buildEnhancedAlertCard(
                                '$expiringCount món sắp hết hạn!',
                                'Hãy sử dụng sớm để tránh lãng phí',
                                Icons.access_time_rounded,
                                const Color(0xFFFFF8E1),
                                const Color(0xFFFF8F00),
                                null,
                              ),
                            if (expiredCount > 0)
                              Padding(
                                padding: EdgeInsets.only(top: expiringCount > 0 ? 12 : 0),
                                child: _buildEnhancedAlertCard(
                                  '$expiredCount món đã hết hạn!',
                                  'Cần xử lý ngay để đảm bảo an toàn',
                                  Icons.warning_rounded,
                                  const Color(0xFFFFEBEE),
                                  const Color(0xFFE53935),
                                  _deleteExpiredItems,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  SliverToBoxAdapter(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          Text(
                            'Sắp xếp theo:',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: currentTextPrimaryColor,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: currentSurfaceColor,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: primaryColor.withOpacity(0.2)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<SortOption>(
                                  value: _selectedSort,
                                  onChanged: _onSortChanged,
                                  icon: Icon(Icons.arrow_drop_down, color: primaryColor),
                                  style: TextStyle(color: currentTextPrimaryColor, fontSize: 14),
                                  dropdownColor: currentSurfaceColor,
                                  isExpanded: true,
                                  items: SortOption.values.map((SortOption option) {
                                    return DropdownMenuItem<SortOption>(
                                      value: option,
                                      child: Row(
                                        children: [
                                          Icon(
                                            _getSortIcon(option),
                                            size: 16,
                                            color: primaryColor,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(_getSortDisplayName(option)),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  SliverToBoxAdapter(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _selectedAreaName,
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: currentTextPrimaryColor,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: primaryColor.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${filteredStorageLogs.length} món',
                              style: TextStyle(
                                fontSize: 14,
                                color: primaryColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  filteredStorageLogs.isEmpty
                      ? SliverFillRemaining(
                    child: Center(child: _buildEmptyState()),
                  )
                      : _buildAdaptiveFoodList(filteredStorageLogs, isTablet),
                  const SliverToBoxAdapter(child: SizedBox(height: 100)),
                ],
              ),
            ),
            if (_isLoading)
              Container(
                color: Colors.black.withOpacity(0.3),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: currentSurfaceColor,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                          strokeWidth: 3.0,
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
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactIconButton(IconData icon, VoidCallback onPressed) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 18),
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
    );
  }

  Widget _buildSmartSearchBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            onChanged: _onSearchChanged,
            style: TextStyle(color: currentTextPrimaryColor),
            decoration: InputDecoration(
              hintText: 'Tìm kiếm thực phẩm...',
              hintStyle: TextStyle(color: currentTextSecondaryColor),
              prefixIcon: Icon(Icons.search, color: primaryColor),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_searchQuery.isNotEmpty)
                    IconButton(
                      icon: Icon(Icons.clear, color: currentTextSecondaryColor),
                      onPressed: () {
                        _searchController.clear();
                        _onSearchChanged('');
                      },
                    ),
                ],
              ),
              filled: true,
              fillColor: currentSurfaceColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: primaryColor.withOpacity(0.2)), // Fixed line 1318
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: primaryColor, width: 2), // Fixed line 1322
              ),
            ),
          ),
          // ... (rest of the method remains unchanged)
        ],
      ),
    );
  }
  Widget _buildResponsiveActionGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final crossAxisCount = screenWidth > 600 ? 4 : 2;
        final childAspectRatio = screenWidth > 600 ? 1.2 : 1.0;
        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: crossAxisCount,
          childAspectRatio: childAspectRatio,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          children: [
            _buildNewActionButton(
              'Thêm thực phẩm',
              'Thêm món mới',
              Icons.add_rounded,
              addFoodColor,
              const Color(0xFFE3F2FD),
                  () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AddFoodScreen(
                      uid: widget.uid,
                      token: widget.token,
                      isDarkMode: _isDarkMode,
                    ),
                  ),
                ).then((value) async {
                  if (value == true) await _fetchStorageLogs(page: 0);
                });
              },
            ),
            _buildNewActionButton(
              'Gợi ý món ăn',
              'Tìm công thức phù hợp',
              Icons.restaurant_menu_rounded,
              recipeColor,
              const Color(0xFFE8F5E8),
                  () => _showRecipeSuggestions(_storageLogs),
            ),
            _buildNewActionButton(
              'Danh sách mua',
              'Quản lý mua sắm',
              Icons.shopping_cart_rounded,
              shoppingColor,
              const Color(0xFFF3E5F5),
                  () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => CartScreen(userId: widget.uid, isDarkMode: _isDarkMode),
                  ),
                );
              },
            ),
            _buildNewActionButton(
              'Kế hoạch ăn uống',
              'Tạo thực đơn chi tiết',
              Icons.calendar_month_rounded,
              cleanupColor, // Sử dụng lại màu của nút cũ
              const Color(0xFFFFF3E0),
                  () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => MealPlanScreen(
                      userId: widget.uid,
                      isDarkMode: _isDarkMode,
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
  Widget _buildAdaptiveFoodList(List<Map<String, dynamic>> filteredLogs, bool isTablet) {
    final displayedLogs = filteredLogs.take(_displayedItems).toList();
    if (isTablet) {
      return SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 3.0,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
        ),
        delegate: SliverChildBuilderDelegate(
              (context, index) {
            if (index >= displayedLogs.length) return const SizedBox.shrink();
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              child: _buildSwipeableFoodItem(displayedLogs[index], index),
            );
          },
          childCount: displayedLogs.length,
        ),
      );
    } else {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
              (context, index) {
            if (index >= displayedLogs.length) return const SizedBox.shrink();
            return _buildSwipeableFoodItem(displayedLogs[index], index);
          },
          childCount: displayedLogs.length,
        ),
      );
    }
  }

  Widget _buildSwipeableFoodItem(Map<String, dynamic> log, int index) {
    return Dismissible(
      key: Key(log['id']),
      background: Container(
        margin: const EdgeInsets.only(left: 20, right: 20, bottom: 16),
        decoration: BoxDecoration(
          color: successColor,
          borderRadius: BorderRadius.circular(20),
        ),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: const Icon(Icons.edit, color: Colors.white, size: 24),
      ),
      secondaryBackground: Container(
        margin: const EdgeInsets.only(left: 20, right: 20, bottom: 16),
        decoration: BoxDecoration(
          color: errorColor,
          borderRadius: BorderRadius.circular(20),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white, size: 24),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          return await _showDeleteConfirmDialog();
        } else {
          final value = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => FoodDetailScreen(
                storageLogId: log['id'],
                userId: widget.uid,
                initialLog: log,
                isDarkMode: _isDarkMode,
              ),
            ),
          );
          if (value is Map<String, dynamic>) {
            if (value['refreshFoods'] == true && value['foodId'] != null) {
              _nameCache['food_${value['foodId']}'] = value['foodName'] ?? 'Unknown Food';
            }
            if (value['refreshStorageLogs'] == true) {
              await _fetchStorageLogs(page: 0);
            }
          }
          return false;
        }
      },
      child: _buildModernFoodItem(log, index),
    );
  }

  IconData _getSortIcon(SortOption option) {
    switch (option) {
      case SortOption.category: return Icons.category;
      case SortOption.expiryDate: return Icons.schedule;
      case SortOption.createdDate: return Icons.calendar_today;
      case SortOption.fresh: return Icons.check_circle;
      case SortOption.expiring: return Icons.warning;
      case SortOption.expired: return Icons.error;
      case SortOption.name: return Icons.sort_by_alpha;
    }
  }

  Widget _buildAnimatedQuickStat(String value, String label, IconData icon, int index) {
    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, 20 * (1 - _animationController.value)),
          child: Opacity(
            opacity: _animationController.value,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.3)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: Colors.white, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        value,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withOpacity(0.8),
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildQuickStat(String value, String label, IconData icon) {
    return Expanded(
      child: Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 16),
              const SizedBox(width: 6),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(0.8),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModernAreaFilter(String? areaId, String areaName, IconData icon) {
    final isSelected = _selectedAreaId == areaId;
    final itemCount = areaId == null
        ? _storageLogs.length
        : _storageLogs.where((log) => log['areaId'] == areaId).length;
    return GestureDetector(
      onTap: () => _selectArea(areaId, areaName),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            margin: const EdgeInsets.only(right: 8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                gradient: isSelected
                    ? LinearGradient(colors: [primaryColor, accentColor])
                    : null,
                color: isSelected ? null : currentSurfaceColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected ? Colors.transparent : (_isDarkMode ? Colors.grey[700]! : Colors.grey[200]!),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: isSelected
                        ? primaryColor.withOpacity(0.3)
                        : Colors.black.withOpacity(0.05),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    color: isSelected ? Colors.white : currentTextPrimaryColor,
                    size: 24,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    areaName,
                    style: TextStyle(
                      color: isSelected ? Colors.white : currentTextPrimaryColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: -6,
            right: 2,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.elasticOut,
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: isSelected
                    ? Colors.white
                    : itemCount > 0
                    ? primaryColor
                    : (_isDarkMode ? Colors.grey[600]! : Colors.grey[400]!),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected
                      ? primaryColor
                      : (_isDarkMode ? Colors.grey[500]! : Colors.grey[300]!),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Text(
                '$itemCount',
                style: TextStyle(
                  color: isSelected
                      ? primaryColor
                      : itemCount > 0
                      ? Colors.white
                      : (_isDarkMode ? Colors.white : Colors.black87),
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNewActionButton(
      String title,
      String subtitle,
      IconData icon,
      Color iconColor,
      Color backgroundColor,
      VoidCallback onPressed) {
    return Container(
      height: 140,
      decoration: BoxDecoration(
        color: _isDarkMode ? backgroundColor.withOpacity(0.2) : backgroundColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: iconColor.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: iconColor,
                    borderRadius: BorderRadius.circular(12),
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
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: currentTextPrimaryColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: currentTextSecondaryColor,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEnhancedAlertCard(
      String title,
      String subtitle,
      IconData icon,
      Color backgroundColor,
      Color iconColor,
      VoidCallback? onActionPressed) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _isDarkMode ? backgroundColor.withOpacity(0.2) : backgroundColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: iconColor.withOpacity(0.2),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: iconColor.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              color: iconColor,
              size: 24,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: iconColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 14,
                    color: iconColor.withOpacity(0.8),
                  ),
                ),
              ],
            ),
          ),
          if (onActionPressed != null) ...[
            const SizedBox(width: 16),
            Container(
              decoration: BoxDecoration(
                color: iconColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _isDeletingExpired ? null : onActionPressed,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: _isDeletingExpired
                        ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                        : Text(
                      'Xóa ngay',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModernFoodItem(Map<String, dynamic> log, int index) {
    final logId = log['id'] as String?;
    if (logId == null) return const SizedBox.shrink();
    final foodName = log['foodName'] as String? ?? 'Unknown Food';
    final expiryDate = log['expiryDate'] as DateTime?;
    final areaName = log['areaName'] as String? ?? 'Unknown Area';
    final quantity = log['quantity']?.toString() ?? '0';
    final unitName = log['unitName'] as String? ?? 'Unknown Unit';
    final categoryName = log['categoryName'] as String? ?? 'Unknown Category';
    final status = log['status'] as String? ?? 'unknown';
    Color statusColor;
    String statusText;
    IconData statusIcon;
    switch (status) {
      case 'expired':
        statusColor = errorColor;
        statusText = 'Hết hạn';
        statusIcon = Icons.error_rounded;
        break;
      case 'expiring':
        statusColor = warningColor;
        statusText = 'Sắp hết hạn';
        statusIcon = Icons.warning_rounded;
        break;
      case 'fresh':
        statusColor = successColor;
        statusText = 'Tươi';
        statusIcon = Icons.check_circle_rounded;
        break;
      default:
        statusColor = currentTextSecondaryColor;
        statusText = 'Không rõ';
        statusIcon = Icons.help_rounded;
    }
    return Container(
      margin: const EdgeInsets.only(left: 20, right: 20, bottom: 16),
      decoration: BoxDecoration(
        color: currentSurfaceColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(_isDarkMode ? 0.3 : 0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => FoodDetailScreen(
                  storageLogId: logId,
                  userId: widget.uid,
                  initialLog: log,
                  isDarkMode: _isDarkMode,
                ),
              ),
            ).then((value) async {
              if (value is Map<String, dynamic>) {
                if (value['refreshFoods'] == true && value['foodId'] != null) {
                  _nameCache['food_${value['foodId']}'] = value['foodName'] ?? 'Unknown Food';
                }
                if (value['refreshStorageLogs'] == true) await _fetchStorageLogs(page: 0);
              }
            });
          },
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [statusColor.withOpacity(0.2), statusColor.withOpacity(0.1)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    _getFoodIcon(foodName),
                    color: statusColor,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_selectedSort == SortOption.category)
                        Text(
                          categoryName,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: currentTextSecondaryColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      Text(
                        foodName,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: currentTextPrimaryColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '$quantity $unitName • $areaName',
                        style: TextStyle(
                          fontSize: 14,
                          color: currentTextSecondaryColor,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'HSD: ${expiryDate != null ? _dateFormat.format(expiryDate) : 'Không rõ'}',
                        style: TextStyle(
                          fontSize: 14,
                          color: currentTextSecondaryColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: statusColor.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(statusIcon, color: statusColor, size: 16),
                      const SizedBox(width: 6),
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: currentSurfaceColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(_isDarkMode ? 0.3 : 0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [primaryColor.withOpacity(0.2), primaryColor.withOpacity(0.1)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              _selectedAreaId == null
                  ? Icons.inventory_2_rounded
                  : getIconForArea(_selectedAreaName),
              size: 64,
              color: primaryColor,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            _storageLogs.isEmpty
                ? 'Chưa có thực phẩm nào'
                : 'Không có thực phẩm trong $_selectedAreaName',
            style: TextStyle(
              fontSize: 20,
              color: currentTextPrimaryColor,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            _storageLogs.isEmpty
                ? 'Thêm thực phẩm đầu tiên của bạn!'
                : 'Thêm thực phẩm vào khu vực này!',
            style: TextStyle(
              fontSize: 16,
              color: currentTextSecondaryColor,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AddFoodScreen(
                    uid: widget.uid,
                    token: widget.token,
                    isDarkMode: _isDarkMode,
                  ),
                ),
              ).then((value) async {
                if (value == true) await _fetchStorageLogs(page: 0);
              });
            },
            icon: const Icon(Icons.add),
            label: const Text('Thêm thực phẩm'),
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getStatus(DateTime? expiryDate) {
    if (expiryDate == null) return 'unknown';
    final now = DateTime.now().toUtc().add(const Duration(hours: 7));
    final daysLeft = expiryDate.difference(now).inDays;
    if (daysLeft < 0) return 'expired';
    if (daysLeft <= 3) return 'expiring';
    return 'fresh';
  }
}