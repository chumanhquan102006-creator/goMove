class BookingIntent {
  final String customerPublicId;
  final String quotePublicId;
  final String idempotencyKey;

  const BookingIntent(
      {required this.customerPublicId,
      required this.quotePublicId,
      required this.idempotencyKey});

  Map<String, String> toJson() => {
        'customerPublicId': customerPublicId,
        'quotePublicId': quotePublicId,
        'idempotencyKey': idempotencyKey,
      };

  factory BookingIntent.fromJson(Map<String, dynamic> json) => BookingIntent(
        customerPublicId: json['customerPublicId'] as String,
        quotePublicId: json['quotePublicId'] as String,
        idempotencyKey: json['idempotencyKey'] as String,
      );
}
