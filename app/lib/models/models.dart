// Traccar API のデータ型（段階1で使うもの）

DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v as String)?.toLocal();
double _double(dynamic v) => v == null ? 0 : (v as num).toDouble();

class User {
  User({required this.id, required this.name, required this.email, required this.administrator, required this.attributes});

  final int id;
  final String name;
  final String email;
  final bool administrator;
  final Map<String, dynamic> attributes;

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: j['id'] as int,
        name: (j['name'] ?? '') as String,
        email: (j['email'] ?? '') as String,
        administrator: (j['administrator'] ?? false) as bool,
        attributes: Map<String, dynamic>.from((j['attributes'] ?? {}) as Map),
      );
}

class Device {
  Device({
    required this.id,
    required this.name,
    required this.uniqueId,
    required this.status,
    required this.lastUpdate,
    required this.positionId,
    required this.category,
    required this.phone,
    required this.model,
    required this.disabled,
  });

  final int id;
  final String name;
  final String uniqueId;
  final String status; // online / offline / unknown
  final DateTime? lastUpdate;
  final int positionId;
  final String? category;
  final String? phone;
  final String? model;
  final bool disabled;

  bool get isOnline => status == 'online';

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        id: j['id'] as int,
        name: (j['name'] ?? '') as String,
        uniqueId: (j['uniqueId'] ?? '') as String,
        status: (j['status'] ?? 'unknown') as String,
        lastUpdate: _date(j['lastUpdate']),
        positionId: (j['positionId'] ?? 0) as int,
        category: j['category'] as String?,
        phone: j['phone'] as String?,
        model: j['model'] as String?,
        disabled: (j['disabled'] ?? false) as bool,
      );
}

class Position {
  Position({
    required this.id,
    required this.deviceId,
    required this.fixTime,
    required this.valid,
    required this.latitude,
    required this.longitude,
    required this.speed,
    required this.course,
    required this.address,
    required this.attributes,
  });

  final int id;
  final int deviceId;
  final DateTime? fixTime;
  final bool valid;
  final double latitude;
  final double longitude;
  final double speed; // ノット
  final double course;
  final String? address;
  final Map<String, dynamic> attributes;

  bool? get motion => attributes['motion'] as bool?;
  bool? get ignition => attributes['ignition'] as bool?;
  int? get satellites => (attributes['sat'] as num?)?.toInt();
  double? get batteryLevel => (attributes['batteryLevel'] as num?)?.toDouble();

  factory Position.fromJson(Map<String, dynamic> j) => Position(
        id: j['id'] as int,
        deviceId: j['deviceId'] as int,
        fixTime: _date(j['fixTime']),
        valid: (j['valid'] ?? false) as bool,
        latitude: _double(j['latitude']),
        longitude: _double(j['longitude']),
        speed: _double(j['speed']),
        course: _double(j['course']),
        address: j['address'] as String?,
        attributes: Map<String, dynamic>.from((j['attributes'] ?? {}) as Map),
      );
}

class TrackerEvent {
  TrackerEvent({required this.id, required this.type, required this.deviceId, required this.eventTime, required this.attributes});

  final int id;
  final String type;
  final int deviceId;
  final DateTime? eventTime;
  final Map<String, dynamic> attributes;

  factory TrackerEvent.fromJson(Map<String, dynamic> j) => TrackerEvent(
        id: (j['id'] ?? 0) as int,
        type: (j['type'] ?? '') as String,
        deviceId: (j['deviceId'] ?? 0) as int,
        eventTime: _date(j['eventTime']),
        attributes: Map<String, dynamic>.from((j['attributes'] ?? {}) as Map),
      );
}

// ---------- レポート（段階2：履歴再生） ----------

/// 停車地点（/api/reports/stops）
class StopReport {
  StopReport({required this.startTime, required this.endTime, required this.duration, required this.latitude, required this.longitude, this.address});

  final DateTime startTime;
  final DateTime endTime;
  final Duration duration;
  final double latitude;
  final double longitude;
  final String? address;

  factory StopReport.fromJson(Map<String, dynamic> j) => StopReport(
        startTime: _date(j['startTime'])!,
        endTime: _date(j['endTime'])!,
        duration: Duration(milliseconds: ((j['duration'] ?? 0) as num).toInt()),
        latitude: _double(j['latitude']),
        longitude: _double(j['longitude']),
        address: j['address'] as String?,
      );
}

/// 走行（/api/reports/trips）
class TripReport {
  TripReport({required this.startTime, required this.endTime, required this.duration, required this.distance, required this.maxSpeed});

  final DateTime startTime;
  final DateTime endTime;
  final Duration duration;
  final double distance; // m
  final double maxSpeed; // ノット

  factory TripReport.fromJson(Map<String, dynamic> j) => TripReport(
        startTime: _date(j['startTime'])!,
        endTime: _date(j['endTime'])!,
        duration: Duration(milliseconds: ((j['duration'] ?? 0) as num).toInt()),
        distance: _double(j['distance']),
        maxSpeed: _double(j['maxSpeed']),
      );
}

/// 集計（/api/reports/summary）
class SummaryReport {
  SummaryReport({required this.distance, required this.maxSpeed, required this.averageSpeed});

  final double distance; // m
  final double maxSpeed; // ノット
  final double averageSpeed; // ノット

  factory SummaryReport.fromJson(Map<String, dynamic> j) => SummaryReport(
        distance: _double(j['distance']),
        maxSpeed: _double(j['maxSpeed']),
        averageSpeed: _double(j['averageSpeed']),
      );
}
