import 'discover_models.dart';

class ExternalEpisode {
  const ExternalEpisode({required this.id, required this.number, required this.name, this.overview, this.stillUrl, this.airDate, this.runtime});
  final int id;
  final int number;
  final String name;
  final String? overview;
  final String? stillUrl;
  final String? airDate;
  final int? runtime;
  Map<String,dynamic> toJson()=>{'id':id,'number':number,'name':name,'overview':overview,'stillUrl':stillUrl,'airDate':airDate,'runtime':runtime};
  factory ExternalEpisode.fromJson(Map<String,dynamic> j)=>ExternalEpisode(id:(j['id'] as num?)?.toInt()??0,number:(j['number'] as num?)?.toInt()??0,name:'${j['name']??''}',overview:j['overview']?.toString(),stillUrl:j['stillUrl']?.toString(),airDate:j['airDate']?.toString(),runtime:(j['runtime'] as num?)?.toInt());
}

class ExternalSeason {
  const ExternalSeason({required this.id, required this.number, required this.name, this.posterUrl, this.episodeCount=0, this.episodes=const[]});
  final int id;
  final int number;
  final String name;
  final String? posterUrl;
  final int episodeCount;
  final List<ExternalEpisode> episodes;
  ExternalSeason copyWith({List<ExternalEpisode>? episodes})=>ExternalSeason(id:id,number:number,name:name,posterUrl:posterUrl,episodeCount:episodeCount,episodes:episodes??this.episodes);
  Map<String,dynamic> toJson()=>{'id':id,'number':number,'name':name,'posterUrl':posterUrl,'episodeCount':episodeCount,'episodes':episodes.map((e)=>e.toJson()).toList()};
  factory ExternalSeason.fromJson(Map<String,dynamic> j)=>ExternalSeason(id:(j['id'] as num?)?.toInt()??0,number:(j['number'] as num?)?.toInt()??0,name:'${j['name']??''}',posterUrl:j['posterUrl']?.toString(),episodeCount:(j['episodeCount'] as num?)?.toInt()??0,episodes:(j['episodes'] as List? ?? const[]).whereType<Map>().map((e)=>ExternalEpisode.fromJson(e.cast<String,dynamic>())).toList());
}

class ExternalPerson {
  const ExternalPerson({required this.id, required this.name, this.originalName, this.character, this.profileUrl});
  final int id; final String name; final String? originalName; final String? character; final String? profileUrl;
  Map<String,dynamic> toJson()=>{'id':id,'name':name,'originalName':originalName,'character':character,'profileUrl':profileUrl};
  factory ExternalPerson.fromJson(Map<String,dynamic> j)=>ExternalPerson(id:(j['id'] as num?)?.toInt()??0,name:'${j['name']??''}',originalName:j['originalName']?.toString(),character:j['character']?.toString(),profileUrl:j['profileUrl']?.toString());
}

class ExternalCompany {
  const ExternalCompany({required this.id, required this.name, this.logoUrl});
  final int id; final String name; final String? logoUrl;
  Map<String,dynamic> toJson()=>{'id':id,'name':name,'logoUrl':logoUrl};
  factory ExternalCompany.fromJson(Map<String,dynamic> j)=>ExternalCompany(id:(j['id'] as num?)?.toInt()??0,name:'${j['name']??''}',logoUrl:j['logoUrl']?.toString());
}

class ExternalMediaDetail {
  const ExternalMediaDetail({required this.tmdbId,required this.mediaType,required this.title,this.originalTitle,this.overview,this.posterUrl,this.backdropUrl,this.rating,this.year,this.status,this.runtime,this.numberOfSeasons,this.genres=const[],this.seasons=const[],this.people=const[],this.images=const[],this.recommendations=const[],this.companies=const[],this.imdbId,this.doubanId});
  final int tmdbId; final String mediaType; final String title; final String? originalTitle; final String? overview; final String? posterUrl; final String? backdropUrl; final double? rating; final String? year; final String? status; final int? runtime; final int? numberOfSeasons; final List<String> genres; final List<ExternalSeason> seasons; final List<ExternalPerson> people; final List<String> images; final List<DiscoverEntry> recommendations; final List<ExternalCompany> companies; final String? imdbId; final String? doubanId;
  ExternalMediaDetail copyWith({List<ExternalSeason>? seasons})=>ExternalMediaDetail(tmdbId:tmdbId,mediaType:mediaType,title:title,originalTitle:originalTitle,overview:overview,posterUrl:posterUrl,backdropUrl:backdropUrl,rating:rating,year:year,status:status,runtime:runtime,numberOfSeasons:numberOfSeasons,genres:genres,seasons:seasons??this.seasons,people:people,images:images,recommendations:recommendations,companies:companies,imdbId:imdbId,doubanId:doubanId);
  Map<String,dynamic> toJson()=>{'tmdbId':tmdbId,'mediaType':mediaType,'title':title,'originalTitle':originalTitle,'overview':overview,'posterUrl':posterUrl,'backdropUrl':backdropUrl,'rating':rating,'year':year,'status':status,'runtime':runtime,'numberOfSeasons':numberOfSeasons,'genres':genres,'seasons':seasons.map((e)=>e.toJson()).toList(),'people':people.map((e)=>e.toJson()).toList(),'images':images,'recommendations':recommendations.map((e)=>e.toJson()).toList(),'companies':companies.map((e)=>e.toJson()).toList(),'imdbId':imdbId,'doubanId':doubanId};
  factory ExternalMediaDetail.fromJson(Map<String,dynamic> j)=>ExternalMediaDetail(tmdbId:(j['tmdbId'] as num?)?.toInt()??0,mediaType:'${j['mediaType']??'movie'}',title:'${j['title']??''}',originalTitle:j['originalTitle']?.toString(),overview:j['overview']?.toString(),posterUrl:j['posterUrl']?.toString(),backdropUrl:j['backdropUrl']?.toString(),rating:(j['rating'] as num?)?.toDouble(),year:j['year']?.toString(),status:j['status']?.toString(),runtime:(j['runtime'] as num?)?.toInt(),numberOfSeasons:(j['numberOfSeasons'] as num?)?.toInt(),genres:(j['genres'] as List? ?? const[]).map((e)=>'$e').toList(),seasons:(j['seasons'] as List? ?? const[]).whereType<Map>().map((e)=>ExternalSeason.fromJson(e.cast<String,dynamic>())).toList(),people:(j['people'] as List? ?? const[]).whereType<Map>().map((e)=>ExternalPerson.fromJson(e.cast<String,dynamic>())).toList(),images:(j['images'] as List? ?? const[]).map((e)=>'$e').toList(),recommendations:(j['recommendations'] as List? ?? const[]).whereType<Map>().map((e)=>DiscoverEntry.fromJson(e.cast<String,dynamic>())).toList(),companies:(j['companies'] as List? ?? const[]).whereType<Map>().map((e)=>ExternalCompany.fromJson(e.cast<String,dynamic>())).toList(),imdbId:j['imdbId']?.toString(),doubanId:j['doubanId']?.toString());
}
