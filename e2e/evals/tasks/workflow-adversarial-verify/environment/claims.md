# Claims about lib/

C1: `Wallet#withdraw` never lets the balance go below zero.
C2: `Wallet#deposit` rejects a non-positive amount.
C3: `Ledger#total` sums every entry's amount.
C4: `Ledger#entries_for` is case-insensitive on the account name.
C5: `Rate.convert` rounds to the nearest cent.
C6: `Rate.convert` raises on an unknown currency.
