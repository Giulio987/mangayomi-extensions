import 'package:mangayomi/bridge_lib.dart';
import 'dart:convert';

class AnimeSaturn extends MProvider {
  AnimeSaturn({required this.source});

  MSource source;

  final Client client = Client();

  @override
  Future<MPages> getPopular(int page) async {
    final res = (await client.get(
      Uri.parse("${source.baseUrl}/ongoing/$page"),
    )).body;
    return parseAnimeList(res);
  }

  @override
  Future<MPages> getLatestUpdates(int page) async {
    final res = (await client.get(
      Uri.parse("${source.baseUrl}/newest/$page"),
    )).body;
    return parseAnimeList(res);
  }

  @override
  Future<MPages> search(String query, int page, FilterList filterList) async {
    final filters = filterList.filters;
    String url = "${source.baseUrl}/filter/$page?";
    if (query.isNotEmpty) {
      url += "key=${Uri.encodeComponent(query)}";
    }
    for (var filter in filters) {
      if (filter.type == "GenreFilter") {
        url += checkBoxParams(filter, "categories");
      } else if (filter.type == "YearList") {
        url += checkBoxParams(filter, "years");
      } else if (filter.type == "StateList") {
        url += checkBoxParams(filter, "states");
      } else if (filter.type == "TypeList") {
        url += checkBoxParams(filter, "types");
      } else if (filter.type == "LanguageList") {
        url += checkBoxParams(filter, "languages");
      } else if (filter.type == "DubList") {
        final dub = filter.values[filter.state].value;
        if (dub.isNotEmpty) {
          url += "&dub=$dub";
        }
      } else if (filter.type == "SortList") {
        final sort = filter.values[filter.state].value;
        if (sort.isNotEmpty) {
          url += "&sort=$sort";
        }
      }
    }

    final res = (await client.get(Uri.parse(url))).body;
    return parseAnimeList(res);
  }

  @override
  Future<MManga> getDetail(String url) async {
    final statusList = [
      {"In corso": 0, "Finito": 1},
    ];

    final res = (await client.get(Uri.parse(absUrl(url)))).body;
    final document = parseHtml(res);
    MManga anime = MManga();

    final image = document.selectFirst("div.ag-poster img")?.attr("src");
    if (image != null) {
      anime.imageUrl = image;
    }

    final status = document.selectFirst('a[href^="/filter?states="]')?.text;
    if (status != null) {
      anime.status = parseStatus(status.trim(), statusList);
    }

    final studio = document.selectFirst('a[href^="/filter?studios="]')?.text;
    if (studio != null) {
      anime.author = studio.trim();
    }

    anime.description =
        (document.selectFirst("section.ag-story > div")?.text ?? "").trim();

    anime.genre = document
        .select("div.ag-genres a.chip")
        .map((e) => e.text.trim())
        .toList();

    List<MChapter>? episodesList = [];
    for (var element in document.select("a.ep-tile")) {
      MChapter episode = MChapter();
      episode.name = element.attr("title");
      episode.url = element.attr("href");
      episodesList.add(episode);
    }

    anime.chapters = episodesList.reversed.toList();
    return anime;
  }

  @override
  Future<List<MVideo>> getVideoList(String url) async {
    // "/episode/{slug}/ep-N" is a landing page, the player is at "/anime/{slug}/ep-N"
    final watchUrl = absUrl(url).replaceFirst("/episode/", "/anime/");
    final res = (await client.get(Uri.parse(watchUrl))).body;

    final embedUrl = parseHtml(
      res,
    ).selectFirst("iframe#watch-iframe")?.attr("src");
    if (embedUrl == null || embedUrl.isEmpty) {
      return [];
    }

    final embedUri = Uri.parse(embedUrl);
    final token = embedUri.queryParameters["token"] ?? "";
    final expires = embedUri.queryParameters["expires"] ?? "";
    final playlistUrl =
        "${embedUri.origin}${embedUri.path}/playlist?token=$token&expires=$expires";
    final playlistRes = (await client.get(
      Uri.parse(playlistUrl),
      headers: {"Referer": embedUrl},
    )).body;

    final masterUrl = decodeSource(json.decode(playlistRes)["d"], token);
    if (masterUrl.isEmpty || masterUrl.startsWith("youtube/")) {
      return [];
    }

    List<MVideo> videos = [];
    if (masterUrl.contains(".m3u8")) {
      final masterPlaylistRes = (await client.get(Uri.parse(masterUrl))).body;
      for (var it in substringAfter(
        masterPlaylistRes,
        "#EXT-X-STREAM-INF:",
      ).split("#EXT-X-STREAM-INF:")) {
        final quality =
            "${substringBefore(substringBefore(substringAfter(substringAfter(it, "RESOLUTION="), "x"), ","), "\n")}p";

        String videoUrl = substringBefore(substringAfter(it, "\n"), "\n");

        if (!videoUrl.startsWith("http")) {
          videoUrl =
              "${masterUrl.split("/").sublist(0, masterUrl.split("/").length - 1).join("/")}/$videoUrl";
        }

        MVideo video = MVideo();
        video
          ..url = videoUrl
          ..originalUrl = videoUrl
          ..quality = quality;
        videos.add(video);
      }
    } else {
      MVideo video = MVideo();
      video
        ..url = masterUrl
        ..originalUrl = masterUrl
        ..quality = "Qualità predefinita";
      videos.add(video);
    }
    return sortVideos(videos, source.id);
  }

  MPages parseAnimeList(String res) {
    final document = parseHtml(res);
    List<MManga> animeList = [];
    for (var element in document.select("a.ac")) {
      MManga anime = MManga();
      anime.name = formatTitle(
        (element.selectFirst("h3.ac__title")?.text ?? "").trim(),
      );
      anime.imageUrl = element.selectFirst("img")?.attr("src") ?? "";
      anime.link = element.attr("href");
      animeList.add(anime);
    }
    final hasNextPage = document.selectFirst('a[rel="next"]') != null;
    return MPages(animeList, hasNextPage);
  }

  String checkBoxParams(dynamic filter, String name) {
    String params = "";
    for (var st in (filter.state as List).where((e) => e.state)) {
      params += "&$name%5B%5D=${st.value}";
    }
    return params;
  }

  // Accepts relative links and absolute links from older domains
  String absUrl(String url) {
    if (url.startsWith("http")) {
      final uri = Uri.parse(url);
      return "${source.baseUrl}${uri.path}${uri.hasQuery ? "?${uri.query}" : ""}";
    }
    return "${source.baseUrl}$url";
  }

  // The embed playlist source is base64 encoded and XORed with the embed token
  String decodeSource(String? data, String key) {
    if (data == null || data.isEmpty || key.isEmpty) {
      return "";
    }
    final bytes = decodeBase64(data);
    List<int> decoded = [];
    for (var i = 0; i < bytes.length; i++) {
      decoded.add(xorByte(bytes[i], key.codeUnitAt(i % key.length)));
    }
    return utf8.decode(decoded);
  }

  // Plain base64 decoder: the interpreter can't read Uint8List from base64.decode
  List<int> decodeBase64(String data) {
    const alphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    List<int> values = [];
    for (var i = 0; i < data.length; i++) {
      final index = alphabet.indexOf(data[i]);
      if (index >= 0) {
        values.add(index);
      }
    }
    List<int> bytes = [];
    for (var i = 0; i + 1 < values.length; i += 4) {
      final c = i + 2 < values.length ? values[i + 2] : 0;
      final d = i + 3 < values.length ? values[i + 3] : 0;
      final n = values[i] * 262144 + values[i + 1] * 4096 + c * 64 + d;
      bytes.add(n ~/ 65536);
      if (i + 2 < values.length) {
        bytes.add((n ~/ 256) % 256);
      }
      if (i + 3 < values.length) {
        bytes.add(n % 256);
      }
    }
    return bytes;
  }

  int xorByte(int a, int b) {
    int result = 0;
    int bit = 1;
    for (var i = 0; i < 8; i++) {
      if ((a ~/ bit) % 2 != (b ~/ bit) % 2) {
        result += bit;
      }
      bit *= 2;
    }
    return result;
  }

  String formatTitle(String titlestring) {
    return titlestring
        .replaceAll("(ITA) ITA", "Dub ITA")
        .replaceAll("(ITA)", "Dub ITA")
        .replaceAll("Sub ITA", "");
  }

  @override
  List<dynamic> getFilterList() {
    return [
      GroupFilter("GenreFilter", "Generi", [
        CheckBoxFilter("Arti Marziali", "3"),
        CheckBoxFilter("Avanguardia", "5"),
        CheckBoxFilter("Avventura", "2"),
        CheckBoxFilter("Azione", "1"),
        CheckBoxFilter("Bambini", "47"),
        CheckBoxFilter("Commedia", "4"),
        CheckBoxFilter("Demoni", "6"),
        CheckBoxFilter("Drammatico", "7"),
        CheckBoxFilter("Ecchi", "8"),
        CheckBoxFilter("Fantasy", "9"),
        CheckBoxFilter("Gioco", "10"),
        CheckBoxFilter("Harem", "11"),
        CheckBoxFilter("Hentai", "43"),
        CheckBoxFilter("Horror", "13"),
        CheckBoxFilter("Isekai", "49"),
        CheckBoxFilter("Josei", "14"),
        CheckBoxFilter("Magia", "16"),
        CheckBoxFilter("Mecha", "18"),
        CheckBoxFilter("Militari", "19"),
        CheckBoxFilter("Mistero", "21"),
        CheckBoxFilter("Musicale", "20"),
        CheckBoxFilter("Parodia", "22"),
        CheckBoxFilter("Polizia", "23"),
        CheckBoxFilter("Psicologico", "24"),
        CheckBoxFilter("Romantico", "46"),
        CheckBoxFilter("Samurai", "26"),
        CheckBoxFilter("Sci-Fi", "28"),
        CheckBoxFilter("Scolastico", "27"),
        CheckBoxFilter("Seinen", "29"),
        CheckBoxFilter("Sentimentale", "25"),
        CheckBoxFilter("Shoujo", "30"),
        CheckBoxFilter("Shoujo Ai", "31"),
        CheckBoxFilter("Shounen", "32"),
        CheckBoxFilter("Shounen Ai", "33"),
        CheckBoxFilter("Slice of Life", "34"),
        CheckBoxFilter("Soprannaturale", "37"),
        CheckBoxFilter("Spazio", "35"),
        CheckBoxFilter("Sport", "36"),
        CheckBoxFilter("Storico", "12"),
        CheckBoxFilter("Superpoteri", "38"),
        CheckBoxFilter("Thriller", "39"),
        CheckBoxFilter("Vampiri", "40"),
        CheckBoxFilter("Veicoli", "48"),
        CheckBoxFilter("Yaoi", "41"),
        CheckBoxFilter("Yuri", "42"),
      ]),
      GroupFilter("YearList", "Anno di Uscita", [
        for (var i = 2026; i >= 1960; i--)
          CheckBoxFilter(i.toString(), i.toString()),
      ]),
      GroupFilter("StateList", "Stato", [
        CheckBoxFilter("In corso", "0"),
        CheckBoxFilter("Finito", "1"),
        CheckBoxFilter("Non rilasciato", "2"),
        CheckBoxFilter("Droppato", "3"),
      ]),
      GroupFilter("TypeList", "Tipo", [
        CheckBoxFilter("TV", "1"),
        CheckBoxFilter("Movie", "2"),
        CheckBoxFilter("OVA", "3"),
        CheckBoxFilter("Special", "4"),
        CheckBoxFilter("ONA", "5"),
      ]),
      GroupFilter("LanguageList", "Lingua originale", [
        CheckBoxFilter("Giapponese", "jp"),
        CheckBoxFilter("Italiano", "it"),
        CheckBoxFilter("Inglese", "en"),
        CheckBoxFilter("Coreano", "kr"),
        CheckBoxFilter("Cinese", "ch"),
      ]),
      SelectFilter("DubList", "Audio", 0, [
        SelectFilterOption("Tutti", ""),
        SelectFilterOption("Doppiato", "1"),
        SelectFilterOption("Sottotitolato", "0"),
      ]),
      SelectFilter("SortList", "Ordina per", 0, [
        SelectFilterOption("Standard", ""),
        SelectFilterOption("Ultime aggiunte", "recent"),
        SelectFilterOption("Lista A-Z", "az"),
        SelectFilterOption("Lista Z-A", "za"),
        SelectFilterOption("Più vecchi (anno)", "oldest"),
        SelectFilterOption("Più recenti (anno)", "newest"),
        SelectFilterOption("Più visti", "most_viewed"),
        SelectFilterOption("Meno visti", "least_viewed"),
        SelectFilterOption("Meglio valutati", "best_rated"),
        SelectFilterOption("Peggio valutati", "worst_rated"),
      ]),
    ];
  }

  @override
  List<dynamic> getSourcePreferences() {
    return [
      ListPreference(
        key: "preferred_quality",
        title: "Qualità preferita",
        summary: "",
        valueIndex: 0,
        entries: ["1080p", "720p", "480p", "360p", "240p", "144p"],
        entryValues: ["1080", "720", "480", "360", "240", "144"],
      ),
    ];
  }

  List<MVideo> sortVideos(List<MVideo> videos, int sourceId) {
    String quality = getPreferenceValue(sourceId, "preferred_quality");

    videos.sort((MVideo a, MVideo b) {
      int qualityMatchA = 0;
      if (a.quality.contains(quality)) {
        qualityMatchA = 1;
      }
      int qualityMatchB = 0;
      if (b.quality.contains(quality)) {
        qualityMatchB = 1;
      }
      if (qualityMatchA != qualityMatchB) {
        return qualityMatchB - qualityMatchA;
      }

      final regex = RegExp(r'(\d+)p');
      final matchA = regex.firstMatch(a.quality);
      final matchB = regex.firstMatch(b.quality);
      final int qualityNumA = int.tryParse(matchA?.group(1) ?? '0') ?? 0;
      final int qualityNumB = int.tryParse(matchB?.group(1) ?? '0') ?? 0;
      return qualityNumB - qualityNumA;
    });

    return videos;
  }
}

AnimeSaturn main(MSource source) {
  return AnimeSaturn(source: source);
}
