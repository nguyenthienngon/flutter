
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:workmanager/workmanager.dart';
import 'dart:io' show Platform;
import 'package:permission_handler/permission_handler.dart';
import 'dart:ui' as ui;
import 'dart:typed_data';
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
final FirebaseFirestore firestore = FirebaseFirestore.instance;
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
const androidInit = AndroidInitializationSettings('ic_launcher');
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
return daysLeft <= 3 && daysLeft >= 0;
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
});
}

// Hàm tĩnh để hiển thị thông báo
Future<void> _showNotificationStatic(
FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin,
String title,
String body,
int id,
String storageLogId) async {
final ByteData byteData = await _createCustomIconStatic();
final androidBitmap = ByteArrayAndroidBitmap(byteData.buffer.asUint8List());

final androidDetails = AndroidNotificationDetails(
'food_expiry_channel',
'Food Expiry Notifications',
channelDescription: 'Thông báo về thực phẩm sắp hết hạn hoặc đã hết hạn',
importance: Importance.max,
priority: Priority.high,
showWhen: true,
largeIcon: androidBitmap,
);
final notificationDetails = NotificationDetails(android: androidDetails);
await flutterLocalNotificationsPlugin.show(id, title, body, notificationDetails, payload: 'view_details_$storageLogId');
}

// Hàm tĩnh để tạo icon tùy chỉnh
Future<ByteData> _createCustomIconStatic() async {
final recorder = ui.PictureRecorder();
final canvas = Canvas(recorder);
const size = 128.0;

final paint = Paint()
..shader = ui.Gradient.radial(
Offset(size / 2, size / 2),
size / 2,
[Color(0xFF0078D7), Color(0xFF00B294)],
)
..style = PaintingStyle.fill;

canvas.drawCircle(Offset(size / 2, size / 2), size / 2, paint);

final iconPaint = Paint()..color = Colors.white;
TextPainter(
text: TextSpan(
text: String.fromCharCode(Icons.kitchen.codePoint),
style: TextStyle(
fontSize: 64,
fontFamily: Icons.kitchen.fontFamily,
color: Colors.white,
),
),
textDirection: ui.TextDirection.ltr,
)
..layout()
..paint(canvas, Offset(size / 2 - 32, size / 2 - 32));

final picture = recorder.endRecording();
final img = await picture.toImage(size.toInt(), size.toInt());
final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
return byteData!;
}

class HomeScreen extends StatefulWidget {
final String uid;
final String token;
const HomeScreen({super.key, required this.uid, required this.token});

@override
_HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
String _filter = 'Tất cả'; // Bộ lọc cho trạng thái thực phẩm
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
_initializeWorkManager();
_fetchInitialData();
_animationController.forward();
}

Future<void> _initializeWorkManager() async {
await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
await Workmanager().registerPeriodicTask(
"check-expiry-task",
"checkExpiryTask",
frequency: const Duration(hours: 24),
inputData: {'userId': widget.uid},
initialDelay: const Duration(minutes: 1),
);
}

Future<void> _initializeNotifications() async {
_notificationsPlugin = FlutterLocalNotificationsPlugin();
const androidInit = AndroidInitializationSettings('ic_launcher');
const initSettings = InitializationSettings(android: androidInit);
await _notificationsPlugin.initialize(
initSettings,
onDidReceiveNotificationResponse: (NotificationResponse response) async {
if (response.payload != null && response.payload!.startsWith('view_details_')) {
final storageLogId = response.payload!.replaceFirst('view_details_', '');
// Fetch the storage log to pass to FoodDetailScreen
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
print('Error fetching storage log for notification: $e');
}
}
},
);

if (Platform.isAndroid) {
var status = await Permission.notification.status;
if (status.isDenied) {
await Permission.notification.request();
}
}
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
ScaffoldMessenger.of(context).showSnackBar(
SnackBar(content: Text('Lỗi khi tải dữ liệu: $e')),
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
final response = await http.get(
url,
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

// Sort logs by expiry date (ascending, nulls last)
processedLogs.sort((a, b) {
final aExpiry = a['expiryDate'] as DateTime?;
final bExpiry = b['expiryDate'] as DateTime?;
if (aExpiry == null && bExpiry == null) return 0;
if (aExpiry == null) return 1;
if (bExpiry == null) return -1;
return aExpiry.compareTo(bExpiry);
});

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

Future<void> _checkAndNotifyExpiringItems() async {
final now = DateTime.now();
final expiringItems = _storageLogs.where((log) {
final expiryDate = log['expiryDate'] as DateTime?;
if (expiryDate == null) return false;
final daysLeft = expiryDate.difference(now).inDays;
return daysLeft <= 3 && daysLeft >= 0 && !_notifiedLogs.contains(log['id']);
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
return expiryDate != null && expiryDate.isBefore(now) && !_notifiedLogs.contains(log['id']);
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
}

Future<void> _showNotification(String title, String body, int id, String storageLogId) async {
final byteData = await _createCustomIcon();
final androidBitmap = ByteArrayAndroidBitmap(byteData.buffer.asUint8List());

final androidDetails = AndroidNotificationDetails(
'food_expiry_channel',
'Food Expiry Notifications',
channelDescription: 'Thông báo về thực phẩm sắp hết hạn hoặc đã hết hạn',
importance: Importance.max,
priority: Priority.high,
showWhen: true,
largeIcon: androidBitmap,
);
final notificationDetails = NotificationDetails(android: androidDetails);
await _notificationsPlugin.show(id, title, body, notificationDetails, payload: 'view_details_$storageLogId');
}

Future<ByteData> _createCustomIcon() async {
final recorder = ui.PictureRecorder();
final canvas = Canvas(recorder);
const size = 128.0;

final paint = Paint()
..shader = ui.Gradient.radial(
Offset(size / 2, size / 2),
size / 2,
[Color(0xFF0078D7), Color(0xFF00B294)],
)
..style = PaintingStyle.fill;

canvas.drawCircle(Offset(size / 2, size / 2), size / 2, paint);

final iconPaint = Paint()..color = Colors.white;
TextPainter(
text: TextSpan(
text: String.fromCharCode(Icons.kitchen.codePoint),
style: TextStyle(
fontSize: 64,
fontFamily: Icons.kitchen.fontFamily,
color: Colors.white,
),
),
textDirection: ui.TextDirection.ltr,
)
..layout()
..paint(canvas, Offset(size / 2 - 32, size / 2 - 32));

final picture = recorder.endRecording();
final img = await picture.toImage(size.toInt(), size.toInt());
final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
return byteData!;
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
'',
);
await _fetchStorageLogs();
} catch (e) {
print('Lỗi khi xóa: $e');
await _showNotification(
'Lỗi',
'Không thể xóa dữ liệu, vui lòng thử lại!',
1,
'',
);
} finally {
if (mounted) setState(() => _isLoading = false);
}
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

void _selectArea(String? areaId, String areaName) {
setState(() {
_selectedAreaId = areaId;
_selectedAreaName = areaName;
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

// Hàm lọc danh sách thực phẩm theo trạng thái
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
return daysLeft <= 3 && daysLeft >= 0;
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

// Lọc danh sách theo khu vực và trạng thái
List<Map<String, dynamic>> filteredStorageLogs = _selectedAreaId == null
? _storageLogs
    : _storageLogs.where((log) => log['areaId'] == _selectedAreaId).toList();

filteredStorageLogs = _filterStorageLogs(filteredStorageLogs);

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
colors: [Colors.amber[50]!, Colors.amber[100]!],
),
borderRadius: BorderRadius.circular(16),
border: Border.all(color: Colors.amber[200]!),
),
child: Row(
children: [
Container(
padding: const EdgeInsets.all(8),
decoration: BoxDecoration(
color: Colors.amber[100]!,
borderRadius: BorderRadius.circular(12),
),
child: Icon(
Icons.warning_amber_outlined,
color: Colors.amber[700]!,
size: 20,
),
),
const SizedBox(width: 12),
Expanded(
child: Text(
'${_getExpiringItemsCount(filteredStorageLogs)} món sắp hết hạn trong $_selectedAreaName!',
style: TextStyle(
color: Colors.amber[800]!,
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
if (_getExpiredLongAgoCount(filteredStorageLogs) > 0)
Column(
children: [
const SizedBox(height: 16),
Container(
padding: const EdgeInsets.all(16),
decoration: BoxDecoration(
gradient: LinearGradient(
colors: [Colors.red[50]!, Colors.red[100]!],
),
borderRadius: BorderRadius.circular(16),
border: Border.all(color: Colors.red[200]!),
),
child: Row(
children: [
Container(
padding: const EdgeInsets.all(8),
decoration: BoxDecoration(
color: Colors.red[100]!,
borderRadius: BorderRadius.circular(12),
),
child: Icon(
Icons.error_outline,
color: Colors.red[700]!,
size: 20,
),
),
const SizedBox(width: 12),
Expanded(
child: Text(
'${_getExpiredLongAgoCount(filteredStorageLogs)} món đã hết hạn!',
style: TextStyle(
color: Colors.red[800]!,
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
Row(
children: [
DropdownButton<String>(
value: _filter,
items: <String>['Tất cả', 'Tươi', 'Sắp hết hạn', 'Hết hạn']
    .map((String value) {
return DropdownMenuItem<String>(
value: value,
child: Text(
value,
style: TextStyle(
fontSize: 14,
fontWeight: FontWeight.w600,
color: primaryColor,
),
),
);
}).toList(),
onChanged: (String? newValue) {
if (newValue != null) {
setState(() {
_filter = newValue;
});
}
},
underline: Container(),
icon: Icon(
Icons.filter_list,
color: primaryColor,
size: 20,
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
return const SizedBox.shrink();
}
final log = filteredStorageLogs[index];
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
return const SizedBox.shrink();
}

final foodName = log['foodName'] as String? ?? 'Unknown Food';
final storageDate = log['storageDate'] as DateTime?;
final expiryDate = log['expiryDate'] as DateTime?;
final areaName = log['areaName'] as String? ?? 'Unknown Area';
final quantity = log['quantity']?.toString() ?? '0';
final unitName = log['unitName'] as String? ?? 'Unknown Unit';

final daysLeft = expiryDate != null ? expiryDate.difference(DateTime.now()).inDays : 999;

Color statusColor;
String statusText;
IconData statusIcon;

if (daysLeft <= 0) {
statusColor = Colors.red[700]!;
statusText = 'Hết hạn';
statusIcon = Icons.error_outline;
} else if (daysLeft <= 3) {
statusColor = Colors.amber[700]!;
statusText = 'Sắp hết hạn';
statusIcon = Icons.warning_amber_outlined;
} else if (expiryDate == null) {
statusColor = Colors.grey;
statusText = 'Không rõ';
statusIcon = Icons.help_outline;
} else {
statusColor = Colors.green;
statusText = 'Tươi';
statusIcon = Icons.check_circle_outline;
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
duration: const Duration(milliseconds: 300),
curve: Curves.easeInOut,
margin: const EdgeInsets.only(bottom: 12),
padding: const EdgeInsets.all(20),
decoration: BoxDecoration(
gradient: LinearGradient(
colors: [
Colors.white,
statusColor.withOpacity(0.05),
],
begin: Alignment.topLeft,
end: Alignment.bottomRight,
),
borderRadius: BorderRadius.circular(20),
border: Border.all(color: statusColor.withOpacity(0.2)),
boxShadow: [
BoxShadow(
color: statusColor.withOpacity(0.1),
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
colors: [statusColor.withOpacity(0.2), statusColor.withOpacity(0.1)],
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
colors: [statusColor.withOpacity(0.2), statusColor.withOpacity(0.1)],
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
