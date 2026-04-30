class Patient {
  final String patientId;
  final String firstName;
  final String lastName;
  final DateTime? dateOfBirth;
  final String timezone;
  final String? deviceSerialNumber;
  final int batteryLevel;
  final bool isOnline;
  final DateTime? lastSeenAt;

  Patient({
    required this.patientId,
    required this.firstName,
    required this.lastName,
    this.dateOfBirth,
    this.timezone = 'Europe/Istanbul',
    this.deviceSerialNumber,
    this.batteryLevel = 0,
    this.isOnline = false,
    this.lastSeenAt,
  });

  String get fullName => '$firstName $lastName';

  int? get age {
    if (dateOfBirth == null) return null;
    final now = DateTime.now();
    int a = now.year - dateOfBirth!.year;
    if (now.month < dateOfBirth!.month ||
        (now.month == dateOfBirth!.month && now.day < dateOfBirth!.day)) {
      a--;
    }
    return a;
  }

  factory Patient.fromJson(Map<String, dynamic> json) {
    return Patient(
      patientId: json['patient_id'].toString(),
      firstName: json['first_name'] as String? ?? '',
      lastName: json['last_name'] as String? ?? '',
      dateOfBirth: json['date_of_birth'] != null
          ? DateTime.tryParse(json['date_of_birth'].toString())
          : null,
      timezone: json['timezone'] as String? ?? 'Europe/Istanbul',
      deviceSerialNumber: json['device_serial_number'] as String?,
      batteryLevel: (json['battery_level'] as int?) ?? 0,
      isOnline: (json['is_online'] as bool?) ?? false,
      lastSeenAt: json['last_seen_at'] != null
          ? DateTime.tryParse(json['last_seen_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'patient_id': patientId,
        'first_name': firstName,
        'last_name': lastName,
        'date_of_birth': dateOfBirth?.toIso8601String().split('T').first,
        'timezone': timezone,
        'device_serial_number': deviceSerialNumber,
        'battery_level': batteryLevel,
        'is_online': isOnline,
        'last_seen_at': lastSeenAt?.toIso8601String(),
      };

  Patient copyWith({
    String? firstName,
    String? lastName,
    DateTime? dateOfBirth,
    String? timezone,
    String? deviceSerialNumber,
    int? batteryLevel,
    bool? isOnline,
    DateTime? lastSeenAt,
  }) {
    return Patient(
      patientId: patientId,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      timezone: timezone ?? this.timezone,
      deviceSerialNumber: deviceSerialNumber ?? this.deviceSerialNumber,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      isOnline: isOnline ?? this.isOnline,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }
}
