# Currencies

An entry carries a currency code (a three-letter string such as "USD"
or "EUR"), "USD" unless one is given, and Ledger::Money stays an
integer count of the smallest unit whatever the currency. A journal
keeps ONE currency — its first entry's — unless it was built with a
Ledger::Rates table (a base currency and a rate per foreign currency,
`Ledger::Rates.new(base: "USD", table: { "EUR" => 1.25 })`): posting
an entry in any other currency raises Ledger::CurrencyMismatch naming
the currency, and the entry is not recorded. With rates, a balance is
stated in the base currency (each foreign amount times its rate,
rounded to the cent), while Report#totals_by_currency answers the
unconverted sums per currency, `{ "USD" => Money, "EUR" => Money }`,
in the order the currencies first appear. CsvExport.render gains a
`currency` column between `amount` and `memo`.
