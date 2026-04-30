# MediDispense - Smart Pill Dispenser Mobile App

FENS402 dersi kapsamında geliştirilen akıllı ilaç dağıtıcı sisteminin Flutter mobil uygulaması.

## Proje Yapısı

```
lib/
├── main.dart                → Uygulama giriş noktası ve tema ayarları
└── screens/
    └── login_page.dart      → Giriş ekranı
```

## Çalıştırma

1. [Flutter SDK kur](https://docs.flutter.dev/get-started/install)
2. Terminalde:
   ```bash
   cd /Users/rauqe/Desktop/FENS402_MobileAppProject
   flutter create .          # iOS/Android platform dosyalarını oluşturur
   flutter pub get            # Paketleri indirir
   flutter run                # Uygulamayı çalıştırır
   ```

## Planlanan Özellikler

- [x] Login ekranı (e-posta + şifre)
- [ ] Firebase Auth entegrasyonu
- [ ] Face-ID / biyometrik doğrulama
- [ ] Dashboard (ilaç planı, cihaz durumu)
- [ ] İlaç geçmişi görselleştirme
- [ ] Caregiver erişim kontrolü
- [ ] Push notification (ilaç hatırlatma)
