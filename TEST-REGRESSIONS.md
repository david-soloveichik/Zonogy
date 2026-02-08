# Zonogy Regression Notes

Use this file as a pre-change checklist for tricky behaviors that have previously regressed.
Each entry is a brief bug report plus something an LLM should be sure to think about to avoid regressing when editing related code.
Keep entries short and concrete as the LLM should be able to figure the rest out when guided in this way.

- Bug report: Sometimes if window A is in a tiling zone and window B is in temporary zone, then minimizing A also minimizes B.
  - Think about: Focus/activation and sync can race.
