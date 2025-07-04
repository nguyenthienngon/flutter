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
import 'recipe_suggestion_screen.dart';
import 'food_detail_screen.dart';
import 'cart_screen.dart';
import 'config.dart';

// Cache for API responses
final Map<String, String> _nameCache = {};

// Hàm callback cho WorkManager
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final FirebaseFirestore firestore = FirebaseFirestore.instance;
      final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);
      await flutterLocalNotificationsPlugin.initialize(initSettings);

      final String userId = inputData?['userId'] ?? "defaultUserId";
      final now = DateTime.now();
      final dateFormat = DateFormat('dd/MM/yyyy');

      final snapshot = await firestore
          .collection('StorageLogs')
          .where('userId', isEqualTo: userId)
          .get();

      final List<Map<String, dynamic>> storageLogs = snapshot.docs.map((doc) {
        final data = doc.data();
        final expiryDateString = data['expiryDate'] as String?;
        DateTime? expiryDate;

        DateTime? parseDateTime(String? dateString) {
          if (dateString == null || dateString.isEmpty) return null;
          try {
            String cleanedDateString = dateString.replaceAll(RegExp(r'\+00:00\+07:00$'), '+07:00');
            return DateTime.parse(cleanedDateString).toLocal();
          } catch (e) {
            print('Error parsing date "$dateString": $e');
            return null;
          }
        }

        expiryDate = parseDateTime(expiryDateString);
        return {
          ...data,
          'id': doc.id,
          'expiryDate': expiryDate,
        };
      }).toList();

      // Kiểm tra thực phẩm sắp hết hạn (trong 3 ngày)
      final expiringItems = storageLogs.where((log) {
        final expiryDate = log['expiryDate'] as DateTime?;
        if (expiryDate == null) return false;
        final daysLeft = expiryDate.difference(now).inDays;
        return daysLeft <= 3 && daysLeft > 0;
      }).toList();

      for (var item in expiringItems) {
        final logId = item['id'] as String;
        final foodName = item['foodName'] as String? ?? 'Unknown Food';
        await _showNotificationStatic(
          flutterLocalNotificationsPlugin,
          'Thực phẩm sắp hết hạn',
          '$foodName sẽ hết hạn vào ${dateFormat.format(item['expiryDate'])}!',
          logId.hashCode,
          logId,
        );
      }

      // Kiểm tra thực phẩm đã hết hạn
      final expiredItems = storageLogs.where((log) {
        final expiryDate = log['expiryDate'] as DateTime?;
        return expiryDate != null && expiryDate.isBefore(now);
      }).toList();

      for (var item in expiredItems) {
        final logId = item['id'] as String;
        final foodName = item['foodName'] as String? ?? 'Unknown Food';
        await _showNotificationStatic(
          flutterLocalNotificationsPlugin,
          'Thực phẩm đã hết hạn',
          '$foodName đã hết hạn vào ${dateFormat.format(item['expiryDate'])}!',
          logId.hashCode,
          logId,
        );
      }

      return Future.value(true);
    } catch (e) {
      print('Error in background task: $e');
      return Future.value(false);
    }
  });
}

// Hàm tĩnh để hiển thị thông báo
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

// Enum cho sort options
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
  String _filter = 'Tất cả';
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

  // Màu sắc giống Welcome Screen với màu đỏ và vàng mềm mại hơn
  final Color primaryColor = const Color(0xFF0078D7);    // Microsoft Blue
  final Color secondaryColor = const Color(0xFF50E3C2);  // Mint
  final Color accentColor = const Color(0xFF00B294);     // Teal
  final Color successColor = const Color(0xFF00C851);    // Green
  final Color warningColor = const Color(0xFFE67E22);    // Soft Orange - mềm mại hơn
  final Color errorColor = const Color(0xFFE74C3C);      // Soft Red - dịu mắt hơn
  final Color backgroundColor = const Color(0xFFE6F7FF); // Light blue background
  final Color surfaceColor = Colors.white;
  final Color textPrimaryColor = const Color(0xFF202124);
  final Color textSecondaryColor = const Color(0xFF5F6368);

  // Dark mode colors
  final Color darkBackgroundColor = const Color(0xFF121212);
  final Color darkSurfaceColor = const Color(0xFF1E1E1E);
  final Color darkTextPrimaryColor = const Color(0xFFE0E0E0);
  final Color darkTextSecondaryColor = const Color(0xFFB0B0B0);

  // Màu sắc cho các nút action mới
  final Color addFoodColor = const Color(0xFF007AFF);     // Blue
  final Color recipeColor = const Color(0xFF34C759);      // Green
  final Color shoppingColor = const Color(0xFFAF52DE);    // Purple
  final Color cleanupColor = const Color(0xFFFF9500);     // Orange

  final Set<String> _notifiedLogs = {};
  List<Map<String, dynamic>> _storageLogs = [];
  List<Map<String, dynamic>> _storageAreas = [];
  final DateFormat _dateFormat = DateFormat('dd/MM/yyyy');

  // Getters for dynamic colors
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
        DateTime? expiryDate;

        if (logData['expiryDate'] != null) {
          try {
            String expiryDateString = logData['expiryDate'] as String;
            expiryDateString = expiryDateString.replaceAll(RegExp(r'\+00:00\+07:00$'), '+07:00');
            expiryDate = DateTime.parse(expiryDateString).toLocal();
          } catch (e) {
            print('Error parsing expiry date: $e');
          }
        }

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => FoodDetailScreen(
              storageLogId: storageLogId,
              userId: widget.uid,
              initialLog: {
                ...logData,
                'id': storageLogId,
                'expiryDate': expiryDate,
              },
            ),
          ),
        );
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
        _fetchStorageLogs(),
      ]);
    } catch (e) {
      print('Error fetching initial data: $e');
      if (mounted) {
        _showErrorSnackBar('Lỗi khi tải dữ liệu: $e');
      }
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
          });
        }
      } else {
        throw Exception('Failed to fetch storage areas: ${response.body}');
      }
    } catch (e) {
      print('Error fetching storage areas: $e');
      if (mounted) {
        setState(() {
          _storageAreas = [
            {'id': '1', 'name': 'Ngăn mát'},
            {'id': '2', 'name': 'Ngăn đá'},
            {'id': '3', 'name': 'Ngăn cửa'},
            {'id': '4', 'name': 'Kệ trên'},
            {'id': '5', 'name': 'Kệ dưới'},
          ];
        });
      }
    }
  }

  Future<void> _fetchStorageLogs() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      String url = '${Config.getNgrokUrl()}/search_storage_logs?userId=${widget.uid}';

      if (_selectedAreaId != null) {
        url += '&areaId=$_selectedAreaId';
      }

      if (_searchQuery.isNotEmpty) {
        url += '&query=${Uri.encodeComponent(_searchQuery)}';
      }

      // Add sort parameter
      String sortBy = _getSortParameter();
      if (sortBy.isNotEmpty) {
        url += '&sortBy=$sortBy';
      }

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
          DateTime? expiryDate;
          DateTime? storageDate;

          DateTime? parseDateTime(String? dateString) {
            if (dateString == null || dateString.isEmpty) return null;
            try {
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
      final now = DateTime.now();

      final expiringItems = _storageLogs.where((log) {
        final expiryDate = log['expiryDate'] as DateTime?;
        if (expiryDate == null) return false;
        final daysLeft = expiryDate.difference(now).inDays;
        return daysLeft <= 3 && daysLeft > 0 && !_notifiedLogs.contains(log['id']);
      }).toList();

      for (var item in expiringItems) {
        final logId = item['id'] as String;
        final foodName = item['foodName'] as String? ?? 'Unknown Food';
        await _showNotification(
          'Thực phẩm sắp hết hạn',
          '$foodName sẽ hết hạn vào ${_dateFormat.format(item['expiryDate'])}!',
          logId.hashCode,
          logId,
        );
        _notifiedLogs.add(logId);
      }

      final expiredItems = _storageLogs.where((log) {
        final expiryDate = log['expiryDate'] as DateTime?;
        return expiryDate != null &&
            expiryDate.isBefore(now) &&
            !_notifiedLogs.contains(log['id']);
      }).toList();

      for (var item in expiredItems) {
        final logId = item['id'] as String;
        final foodName = item['foodName'] as String? ?? 'Unknown Food';
        await _showNotification(
          'Thực phẩm đã hết hạn',
          '$foodName đã hết hạn vào ${_dateFormat.format(item['expiryDate'])}!',
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

  // Hàm xóa các món đã hết hạn
  Future<void> _deleteExpiredItems() async {
    if (_isDeletingExpired) return;

    setState(() => _isDeletingExpired = true);

    try {
      final now = DateTime.now();
      final expiredItems = _storageLogs.where((log) {
        final expiryDate = log['expiryDate'] as DateTime?;
        return expiryDate != null && expiryDate.isBefore(now);
      }).toList();

      if (expiredItems.isEmpty) {
        _showSuccessSnackBar('Không có món nào đã hết hạn để xóa!');
        return;
      }

      // Xóa từng món đã hết hạn
      for (var item in expiredItems) {
        final logId = item['id'] as String;
        try {
          final url = Uri.parse('${Config.getNgrokUrl()}/delete_storage_log');
          final response = await http.delete(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'storageLogId': logId,
              'userId': widget.uid,
            }),
          );

          if (response.statusCode != 200) {
            print('Failed to delete item $logId: ${response.body}');
          }
        } catch (e) {
          print('Error deleting item $logId: $e');
        }
      }

      // Refresh dữ liệu
      await _fetchStorageLogs();

      _showSuccessSnackBar('Đã xóa ${expiredItems.length} món hết hạn!');

    } catch (e) {
      print('Error deleting expired items: $e');
      _showErrorSnackBar('Lỗi khi xóa món hết hạn: $e');
    } finally {
      if (mounted) setState(() => _isDeletingExpired = false);
    }
  }

  void _selectArea(String? areaId, String areaName) {
    setState(() {
      _selectedAreaId = areaId;
      _selectedAreaName = areaName;
    });
    _fetchStorageLogs();
  }

  void _toggleSearch() {
    setState(() {
      _isSearchVisible = !_isSearchVisible;
      if (!_isSearchVisible) {
        _searchController.clear();
        _searchQuery = '';
        _fetchStorageLogs();
      }
    });
  }

  void _onSearchChanged(String query) {
    setState(() {
      _searchQuery = query;
    });
    // Debounce search
    Future.delayed(const Duration(milliseconds: 500), () {
      if (_searchQuery == query) {
        _fetchStorageLogs();
      }
    });
  }

  void _toggleDarkMode() {
    setState(() {
      _isDarkMode = !_isDarkMode;
    });
  }

  void _onSortChanged(SortOption? newSort) {
    if (newSort != null) {
      setState(() {
        _selectedSort = newSort;
      });
      _fetchStorageLogs();
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
        return Icons.door_front_door_outlined;
      case 'kệ trên':
        return Icons.shelves;
      case 'kệ dưới':
        return Icons.inventory_2_outlined;
      default:
        return Icons.inventory_outlined;
    }
  }

  // Logic tính toán chính xác
  int _getExpiringItemsCount(List<Map<String, dynamic>> logs) {
    final now = DateTime.now();
    final filteredLogs = _selectedAreaId == null
        ? logs
        : logs.where((log) => log['areaId'] == _selectedAreaId).toList();

    return filteredLogs.where((log) {
      final expiryDate = log['expiryDate'] as DateTime?;
      if (expiryDate == null) return false;
      final daysLeft = expiryDate.difference(now).inDays;
      return daysLeft <= 3 && daysLeft > 0;
    }).length;
  }

  int _getExpiredItemsCount(List<Map<String, dynamic>> logs) {
    final now = DateTime.now();
    final filteredLogs = _selectedAreaId == null
        ? logs
        : logs.where((log) => log['areaId'] == _selectedAreaId).toList();

    return filteredLogs.where((log) {
      final expiryDate = log['expiryDate'] as DateTime?;
      return expiryDate != null && expiryDate.isBefore(now);
    }).length;
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
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _filterStorageLogs(List<Map<String, dynamic>> logs) {
    final now = DateTime.now();
    switch (_filter) {
      case 'Tươi':
        return logs.where((log) {
          final expiryDate = log['expiryDate'] as DateTime?;
          return expiryDate == null || expiryDate.difference(now).inDays > 3;
        }).toList();
      case 'Sắp hết hạn':
        return logs.where((log) {
          final expiryDate = log['expiryDate'] as DateTime?;
          if (expiryDate == null) return false;
          final daysLeft = expiryDate.difference(now).inDays;
          return daysLeft <= 3 && daysLeft > 0;
        }).toList();
      case 'Hết hạn':
        return logs.where((log) {
          final expiryDate = log['expiryDate'] as DateTime?;
          return expiryDate != null && expiryDate.isBefore(now);
        }).toList();
      case 'Tất cả':
      default:
        return logs;
    }
  }

  void _showErrorSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: errorColor,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          margin: const EdgeInsets.all(16),
        ),
      );
    }
  }

  void _showSuccessSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    List<Map<String, dynamic>> filteredStorageLogs = _storageLogs;

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
                physics: const BouncingScrollPhysics(),
                slivers: [
                  // Header với màu giống Welcome Screen
                  SliverToBoxAdapter(
                    child: AnimatedBuilder(
                      animation: _fadeAnimation,
                      builder: (context, child) {
                        return Transform.translate(
                          offset: Offset(0, _slideAnimation.value),
                          child: Opacity(
                            opacity: _fadeAnimation.value,
                            child: Container(
                              height: 200,
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
                                  // Background pattern
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
                                  // Content
                                  Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        // Header row
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Container(
                                                      padding: const EdgeInsets.all(8),
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
                                                        size: 24,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 12),
                                                    ShaderMask(
                                                      shaderCallback: (bounds) => LinearGradient(
                                                        colors: [Colors.white, secondaryColor],
                                                        begin: Alignment.topLeft,
                                                        end: Alignment.bottomRight,
                                                      ).createShader(bounds),
                                                      child: const Text(
                                                        'SmartFri',
                                                        style: TextStyle(
                                                          fontSize: 28,
                                                          fontWeight: FontWeight.bold,
                                                          color: Colors.white,
                                                          letterSpacing: 0.5,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  'Quản lý thông minh tủ lạnh',
                                                  style: TextStyle(
                                                    fontSize: 16,
                                                    color: Colors.white.withOpacity(0.9),
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            // Action buttons row
                                            Row(
                                              children: [
                                                // Search button
                                                Container(
                                                  decoration: BoxDecoration(
                                                    color: Colors.white.withOpacity(0.2),
                                                    borderRadius: BorderRadius.circular(16),
                                                    border: Border.all(
                                                      color: Colors.white.withOpacity(0.3),
                                                    ),
                                                  ),
                                                  child: IconButton(
                                                    icon: Icon(
                                                      _isSearchVisible ? Icons.close : Icons.search,
                                                      color: Colors.white,
                                                      size: 24,
                                                    ),
                                                    onPressed: _toggleSearch,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                // Dark mode toggle
                                                Container(
                                                  decoration: BoxDecoration(
                                                    color: Colors.white.withOpacity(0.2),
                                                    borderRadius: BorderRadius.circular(16),
                                                    border: Border.all(
                                                      color: Colors.white.withOpacity(0.3),
                                                    ),
                                                  ),
                                                  child: IconButton(
                                                    icon: Icon(
                                                      _isDarkMode ? Icons.light_mode : Icons.dark_mode,
                                                      color: Colors.white,
                                                      size: 24,
                                                    ),
                                                    onPressed: _toggleDarkMode,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                // Cart button
                                                Container(
                                                  decoration: BoxDecoration(
                                                    color: Colors.white.withOpacity(0.2),
                                                    borderRadius: BorderRadius.circular(16),
                                                    border: Border.all(
                                                      color: Colors.white.withOpacity(0.3),
                                                    ),
                                                  ),
                                                  child: IconButton(
                                                    icon: const Icon(
                                                      Icons.shopping_cart_outlined,
                                                      color: Colors.white,
                                                      size: 24,
                                                    ),
                                                    onPressed: () {
                                                      Navigator.push(
                                                        context,
                                                        MaterialPageRoute(
                                                          builder: (context) => CartScreen(userId: widget.uid),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),

                                        const Spacer(),

                                        // Quick stats row
                                        Row(
                                          children: [
                                            _buildQuickStat('$totalCount', 'Tổng số', Icons.inventory_2_rounded),
                                            const SizedBox(width: 20),
                                            _buildQuickStat('$expiringCount', 'Sắp hết hạn', Icons.warning_rounded),
                                            const SizedBox(width: 20),
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

                  // Search bar (when visible)
                  if (_isSearchVisible)
                    SliverToBoxAdapter(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
                            fillColor: currentSurfaceColor,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(color: primaryColor.withOpacity(0.2)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(color: primaryColor, width: 2),
                            ),
                          ),
                        ),
                      ),
                    ),

                  const SliverToBoxAdapter(child: SizedBox(height: 8)),

                  // Sort and Filter Row
                  SliverToBoxAdapter(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          // Sort dropdown
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: currentSurfaceColor,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: primaryColor.withOpacity(0.2)),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<SortOption>(
                                  value: _selectedSort,
                                  onChanged: _onSortChanged,
                                  icon: Icon(Icons.arrow_drop_down, color: primaryColor),
                                  style: TextStyle(color: currentTextPrimaryColor, fontSize: 14),
                                  dropdownColor: currentSurfaceColor,
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

                  // Area Filters
                  SliverToBoxAdapter(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 20),
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
                          const SizedBox(height: 16),
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

                  // Quick Actions - 2x2 Grid
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
                          // Hàng đầu tiên
                          Row(
                            children: [
                              Expanded(
                                child: _buildNewActionButton(
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
                                        ),
                                      ),
                                    ).then((value) async {
                                      if (value == true) {
                                        await _fetchStorageLogs();
                                      }
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: _buildNewActionButton(
                                  'Gợi ý món ăn',
                                  'Tìm công thức phù hợp',
                                  Icons.restaurant_menu_rounded,
                                  recipeColor,
                                  const Color(0xFFE8F5E8),
                                      () => _showRecipeSuggestions(_storageLogs),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          // Hàng thứ hai
                          Row(
                            children: [
                              Expanded(
                                child: _buildNewActionButton(
                                  'Danh sách mua',
                                  'Quản lý mua sắm',
                                  Icons.shopping_cart_rounded,
                                  shoppingColor,
                                  const Color(0xFFF3E5F5),
                                      () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => CartScreen(userId: widget.uid),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: _buildNewActionButton(
                                  'Dọn dẹp',
                                  'Xóa món hết hạn',
                                  Icons.delete_rounded,
                                  cleanupColor,
                                  const Color(0xFFFFF3E0),
                                  _deleteExpiredItems,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SliverToBoxAdapter(child: SizedBox(height: 24)),

                  // Alert Cards - New Design
                  if (expiringCount > 0 || expiredCount > 0)
                    SliverToBoxAdapter(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          children: [
                            if (expiringCount > 0)
                              _buildNewAlertCard(
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
                                child: _buildNewAlertCard(
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

                  // Food Items Header
                  SliverToBoxAdapter(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '$_selectedAreaName',
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

                  // Food Items List
                  filteredStorageLogs.isEmpty
                      ? SliverFillRemaining(
                    child: Center(child: _buildEmptyState()),
                  )
                      : SliverList(
                    delegate: SliverChildBuilderDelegate(
                          (context, index) {
                        if (index >= filteredStorageLogs.length) {
                          return const SizedBox.shrink();
                        }
                        final log = filteredStorageLogs[index];
                        return _buildModernFoodItem(log, index);
                      },
                      childCount: filteredStorageLogs.length,
                    ),
                  ),

                  // Bottom padding
                  const SliverToBoxAdapter(child: SizedBox(height: 100)),
                ],
              ),
            ),

            // Loading overlay
            if (_isLoading)
              Container(
                color: Colors.black.withOpacity(0.3),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: currentSurfaceColor,
                      borderRadius: BorderRadius.circular(20),
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

  IconData _getSortIcon(SortOption option) {
    switch (option) {
      case SortOption.category:
        return Icons.category;
      case SortOption.expiryDate:
        return Icons.schedule;
      case SortOption.createdDate:
        return Icons.calendar_today;
      case SortOption.fresh:
        return Icons.check_circle;
      case SortOption.expiring:
        return Icons.warning;
      case SortOption.expired:
        return Icons.error;
      case SortOption.name:
        return Icons.sort_by_alpha;
    }
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          gradient: isSelected
              ? LinearGradient(colors: [primaryColor, accentColor])
              : null,
          color: isSelected ? null : currentSurfaceColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? Colors.transparent : (_isDarkMode ? Colors.grey[700]! : Colors.grey[200]!),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: isSelected
                  ? primaryColor.withOpacity(0.3)
                  : Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isSelected ? Colors.white : currentTextPrimaryColor,
              size: 24,
            ),
            const SizedBox(height: 8),
            Text(
              areaName,
              style: TextStyle(
                color: isSelected ? Colors.white : currentTextPrimaryColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isSelected
                    ? Colors.white.withOpacity(0.2)
                    : primaryColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$itemCount',
                style: TextStyle(
                  color: isSelected ? Colors.white : primaryColor,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // New Action Button Design
  Widget _buildNewActionButton(
      String title,
      String subtitle,
      IconData icon,
      Color iconColor,
      Color backgroundColor,
      VoidCallback onPressed
      ) {
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

  // New Alert Card Design
  Widget _buildNewAlertCard(
      String title,
      String subtitle,
      IconData icon,
      Color backgroundColor,
      Color iconColor,
      VoidCallback? onActionPressed,
      ) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _isDarkMode ? backgroundColor.withOpacity(0.2) : backgroundColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: iconColor.withOpacity(0.2),
          width: 1,
        ),
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
    if (logId == null) {
      return const SizedBox.shrink();
    }

    final foodName = log['foodName'] as String? ?? 'Unknown Food';
    final expiryDate = log['expiryDate'] as DateTime?;
    final areaName = log['areaName'] as String? ?? 'Unknown Area';
    final quantity = log['quantity']?.toString() ?? '0';
    final unitName = log['unitName'] as String? ?? 'Unknown Unit';
    final daysLeft = expiryDate != null ? expiryDate.difference(DateTime.now()).inDays : 999;

    Color statusColor;
    String statusText;
    IconData statusIcon;

    if (daysLeft < 0) {
      statusColor = errorColor;
      statusText = 'Hết hạn';
      statusIcon = Icons.error_rounded;
    } else if (daysLeft <= 3) {
      statusColor = warningColor;
      statusText = 'Sắp hết hạn';
      statusIcon = Icons.warning_rounded;
    } else if (expiryDate == null) {
      statusColor = currentTextSecondaryColor;
      statusText = 'Không rõ';
      statusIcon = Icons.help_rounded;
    } else {
      statusColor = successColor;
      statusText = 'Tươi';
      statusIcon = Icons.check_circle_rounded;
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
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                // Icon container
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
                    getIconForArea(areaName),
                    color: statusColor,
                    size: 28,
                  ),
                ),

                const SizedBox(width: 16),

                // Food info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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

                // Status badge
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
        ],
      ),
    );
  }
}
