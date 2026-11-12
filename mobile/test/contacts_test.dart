import 'package:flutter_test/flutter_test.dart';
import 'package:svoi/contacts.dart';

void main() {
  test('номер приводится к +79XXXXXXXXX, остальное отбрасывается', () {
    expect(normalizeRuMobile('8 (914) 123-45-67'), '+79141234567');
    expect(normalizeRuMobile('+7 914 123 45 67'), '+79141234567');
    expect(normalizeRuMobile('9141234567'), '+79141234567');
    expect(normalizeRuMobile('+7 (3022) 12-34-56'), isNull, reason: 'городской');
    expect(normalizeRuMobile('+1 202 555 0100'), isNull);
    expect(normalizeRuMobile('112'), isNull);
  });

  test('хэш совпадает с сервером (тот же вектор в backend/internal/contacts)', () {
    expect(hashPhone('+79141234567'), 'e19773badb6a9e9c6d6f3973c30779dbc14120576cb7e60d4634baf6b2ddb0fc');
  });

  test('повторы и чужие номера не отправляются', () {
    final hashes = hashContacts(['8 914 123-45-67', '+79141234567', '+1 202 555 0100']);
    expect(hashes, hasLength(1));
  });
}
