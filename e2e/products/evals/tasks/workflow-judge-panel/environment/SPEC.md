# slugify(text)

Answer a URL slug for `text`:

1. lower-case;
2. every run of characters that is not a letter or a digit becomes ONE
   hyphen;
3. no leading or trailing hyphen;
4. an empty result (nothing but separators) answers "n-a";
5. the result is at most 40 characters and never ends on a hyphen after
   the cut.
