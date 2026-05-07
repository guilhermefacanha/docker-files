# Turning off i18n by default as translation in most languages are
# incomplete and not well maintained.
BABEL_DEFAULT_LOCALE = "en"

LANGUAGES = {
 'en': {'flag': 'us', 'name': 'English'},
 'pt_BR': {'flag': 'br', 'name': 'Português'},
}

FEATURE_FLAGS = {
 "ALERT_REPORTS": True,
 "ALERT_REPORT_TABS": True,
 "ALLOW_FULL_CSV_EXPORT": True,
 "DASHBOARD_CROSS_FILTERS": True,
}


