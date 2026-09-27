"""The verifier's live lifecycle library (ADR-027 D2, D5). Import modules from here by name.

Never put this directory itself on sys.path: `locale.py` would then shadow the standard library's
`locale`. Put its parent (`Scripts/verify`) there and import `live.<module>`.
"""
