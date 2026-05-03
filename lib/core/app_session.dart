import '../models/patient.dart';

/// Holds the currently logged-in user across the app.
/// Set on login, cleared on logout.
class AppSession {
  AppSession._();
  static final AppSession instance = AppSession._();

  Patient? currentPatient;
  bool isCaregiver = false;
  String? caregiverId;
  String? caregiverEmail;

  void loginAsCaregiver({String? id, String? email}) {
    isCaregiver = true;
    currentPatient = null;
    caregiverId = id;
    caregiverEmail = email;
  }

  void loginAsPatient(Patient patient) {
    isCaregiver = false;
    currentPatient = patient;
  }

  void logout() {
    isCaregiver = false;
    currentPatient = null;
    caregiverId = null;
    caregiverEmail = null;
  }

  String? get currentPatientId => currentPatient?.patientId;
}
