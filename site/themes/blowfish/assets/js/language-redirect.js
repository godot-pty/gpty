(function () {
  var config = window.BlowfishLanguageRedirectConfig;

  if (!config || config.enabled !== true) {
    return;
  }

  function getStorage() {
    if (!config.storageKey) {
      return null;
    }

    try {
      return window.localStorage;
    } catch (error) {
      return null;
    }
  }

  var storage = getStorage();

  function normalizeLanguageTag(value) {
    if (typeof value !== "string") {
      return "";
    }

    return value.trim().toLowerCase().replace(/_/g, "-");
  }

  function getBaseLanguage(value) {
    var languageTag = normalizeLanguageTag(value);

    if (!languageTag) {
      return "";
    }

    return languageTag.split("-")[0];
  }

  function getTranslationTags(translation) {
    if (!translation) {
      return [];
    }

    var tags = [];
    var values = [translation.lang, translation.languageCode];

    for (var i = 0; i < values.length; i += 1) {
      var languageTag = normalizeLanguageTag(values[i]);

      if (languageTag && tags.indexOf(languageTag) === -1) {
        tags.push(languageTag);
      }
    }

    return tags;
  }

  function getCanonicalTranslationTag(translation) {
    var tags = getTranslationTags(translation);

    if (!tags.length) {
      return "";
    }

    return tags.reduce(function (bestTag, languageTag) {
      if (languageTag.split("-").length > bestTag.split("-").length) {
        return languageTag;
      }

      return bestTag;
    }, tags[0]);
  }

  function translationHasTag(translation, languageTag) {
    var normalizedTag = normalizeLanguageTag(languageTag);

    if (!normalizedTag) {
      return false;
    }

    return getTranslationTags(translation).indexOf(normalizedTag) !== -1;
  }

  function getAvailableTranslations() {
    if (!Array.isArray(config.translations)) {
      return [];
    }

    return config.translations.filter(function (translation) {
      return translation && translation.url && getTranslationTags(translation).length > 0;
    });
  }

  var translations = getAvailableTranslations();

  function findExactTranslation(languageTag) {
    var normalizedTag = normalizeLanguageTag(languageTag);

    if (!normalizedTag) {
      return null;
    }

    for (var i = 0; i < translations.length; i += 1) {
      if (translationHasTag(translations[i], normalizedTag)) {
        return translations[i];
      }
    }

    return null;
  }

  function findBaseTranslation(languageTag) {
    var baseLanguage = getBaseLanguage(languageTag);

    if (!baseLanguage) {
      return null;
    }

    for (var i = 0; i < translations.length; i += 1) {
      var tags = getTranslationTags(translations[i]);

      for (var j = 0; j < tags.length; j += 1) {
        if (getBaseLanguage(tags[j]) === baseLanguage) {
          return translations[i];
        }
      }
    }

    return null;
  }

  function findBestTranslation(languageTag) {
    var normalizedTag = normalizeLanguageTag(languageTag);

    if (!normalizedTag) {
      return null;
    }

    while (normalizedTag) {
      var translation = findExactTranslation(normalizedTag);

      if (translation) {
        return translation;
      }

      var lastSubtagIndex = normalizedTag.lastIndexOf("-");

      if (lastSubtagIndex === -1) {
        break;
      }

      normalizedTag = normalizedTag.slice(0, lastSubtagIndex);
    }

    return findBaseTranslation(languageTag);
  }

  function getStoredLanguage() {
    if (!storage || config.storedLanguageRedirect !== true) {
      return null;
    }

    try {
      return storage.getItem(config.storageKey);
    } catch (error) {
      return null;
    }
  }

  function setStoredLanguage(language) {
    if (!storage) {
      return;
    }

    var languageTag = normalizeLanguageTag(language);

    if (!languageTag) {
      return;
    }

    try {
      storage.setItem(config.storageKey, languageTag);
    } catch (error) {
      // Ignore storage errors so the language link keeps its normal behavior.
    }
  }

  function getBrowserTranslation() {
    var languages = [];

    if (Array.isArray(navigator.languages)) {
      languages = languages.concat(navigator.languages);
    }

    if (navigator.language) {
      languages.push(navigator.language);
    }

    for (var i = 0; i < languages.length; i += 1) {
      var translation = findBestTranslation(languages[i]);

      if (translation) {
        return translation;
      }
    }

    if (config.fallbackLanguage) {
      return findBestTranslation(config.fallbackLanguage);
    }

    return null;
  }

  function normalizePath(pathname) {
    if (pathname.length > 1 && pathname.charAt(pathname.length - 1) === "/") {
      return pathname.slice(0, -1);
    }

    return pathname;
  }

  function getUrl(value) {
    try {
      return new URL(value, window.location.origin);
    } catch (error) {
      return null;
    }
  }

  function redirectToTranslation(translation) {
    if (!translation || !translation.url) {
      return false;
    }

    var currentLanguage = getCanonicalTranslationTag({
      lang: config.currentLanguage,
      languageCode: config.currentLanguageCode
    });
    var targetLanguage = getCanonicalTranslationTag(translation);

    if (currentLanguage && targetLanguage && currentLanguage === targetLanguage) {
      return false;
    }

    var targetUrl = getUrl(translation.url);

    if (!targetUrl || normalizePath(targetUrl.pathname) === normalizePath(window.location.pathname)) {
      return false;
    }

    window.location.replace(targetUrl.href);
    return true;
  }

  function redirectToLanguage(language) {
    return redirectToTranslation(findBestTranslation(language));
  }

  function findTranslationByUrl(url) {
    var linkUrl = getUrl(url);

    if (!linkUrl) {
      return null;
    }

    for (var i = 0; i < translations.length; i += 1) {
      var translationUrl = getUrl(translations[i].url);

      if (translationUrl && normalizePath(translationUrl.pathname) === normalizePath(linkUrl.pathname)) {
        return translations[i];
      }
    }

    return null;
  }

  function bindLanguageSwitcher() {
    document.addEventListener("click", function (event) {
      if (!event.target || !event.target.closest) {
        return;
      }

      var link = event.target.closest(".translation a[href]");

      if (!link) {
        return;
      }

      var translation = findTranslationByUrl(link.href);

      if (translation) {
        setStoredLanguage(getCanonicalTranslationTag(translation));
      }
    });
  }

  function maybeRedirect() {
    var storedLanguage = getStoredLanguage();

    if (storedLanguage) {
      redirectToLanguage(storedLanguage);
      return;
    }

    if (config.browserRedirectHomeOnly === true && config.isHome !== true) {
      return;
    }

    var browserTranslation = getBrowserTranslation();

    if (browserTranslation) {
      redirectToTranslation(browserTranslation);
    }
  }

  bindLanguageSwitcher();
  maybeRedirect();
})();
