open Printf
open Cohttp
open Lwt
open Cow

let file_template f =
  try_lwt begin
  lwt tmpl = OS.Devices.find_kv_ro "templates" >>= function
    |Some x -> return x |None -> raise_lwt (Failure "no templates dev") in
  match_lwt tmpl#read f with
  | Some content -> Util.string_of_stream content
  | None -> raise_lwt (Failure (sprintf "File template not found: %s" f))
  end
  with exn -> 
    printf "Pages.read_file: exception %s\n%!" (Printexc.to_string exn);
    exit 1

let read_file f =
  try_lwt
    let suffix =
      try
        let n = String.rindex f '.' in
        String.sub f (n+1) (String.length f - n - 1)
      with _ -> "" 
    in
    match suffix with
      | "md"   -> file_template f >|= Markdown.of_string >|= Markdown.to_html 
      | "html" -> file_template f >|= Html.of_string
      | _      -> return []
  with exn -> 
    printf "Pages.read_file: exception %s\n%!" (Printexc.to_string exn);
    exit 1

let col_files l r = <:xml< 
  <div class="left_column">
    <div class="summary_information"> $l$ </div>
  </div>
  <div class="right_column"> $r$ </div>
>>

let column_css = <:css<
  /* Column Styling */
  .left_column {
    float: left;
    width: 440px;
    text-align: justify;
  }
  .right_column {
    float: right;
    width: 400px;
  }
>>

let none : Html.t = []

let content_type_xhtml = ["content-type","text/html"]

module Index = struct
  let body =
    lwt l1 = read_file "/intro.md" >|= (fun l -> col_files l none) in 
    lwt l2 = read_file "/intro-r.html" >|= (fun l -> col_files l none) in
    return (<:xml<
    <div class="left_column">
      $l1$
    </div> 
    <div class="right_column">
      $l2$
    </div>
    >>)
  let t = Template.t "Home" "home" body >|= Html.to_string
end

module Resources = struct
  let body = read_file "/docs.md" >|= (fun l -> col_files l Paper.html)
  let t = Template.t "Resources" "resources" body >|= Html.to_string
end 

module About = struct
  
  let body =
    lwt l = read_file "/about.md" in
    lwt r = read_file "/about-r.md" in
    return (col_files l r)

  let t = Template.t "About" "about" body >|= Html.to_string
end

module Blog = struct
  open Blog

 
  (* Make a full Html.t including RSS link and headers from a list
     of Html.t entry fragments *)
  let make ?title body =
    let url = sprintf "/blog/atom.xml" in
    let extra_header = <:xml<
     <link rel="alternate" type="application/atom+xml" href=$str:url$ />
    >> in
    let title = "blog" ^ match title with None -> "" | Some x -> " :: " ^ x in
    lwt html = Template.t ~extra_header "Blog" title body in
    return (Html.to_string html)

  (* Main blog page Html.t fragment with all blog posts *)
  let main_page =
    make (Blog.html_of_entries read_file Blog.entries)

  let ent_bodies = Hashtbl.create 1
  let _ =
    List.iter (fun entry ->
      let title = entry.subject in
      let body  = Blog.html_of_entries ~disqus:entry.permalink
        read_file [entry] in
      Hashtbl.add ent_bodies entry.permalink (make ~title body);
    ) Blog.entries

  let atom_feed =
    lwt f = Blog.atom_feed read_file Blog.entries in
    return (Xml.to_string (Atom.xml_of_feed ~self:("/blog/atom.xml") f))

  let not_found x =
    sprintf "Not found: %s (known links: %s)"
      (String.concat " ... " x)
      (String.concat " "
         (Hashtbl.fold (fun k v a -> k :: a)
            ent_bodies []))

  let t = function
    | []                          -> content_type_xhtml, main_page
    | ["atom.xml"]                -> ["content-type","application/atom+xml; charset=UTF-8"], atom_feed
    | [x] when permalink_exists x -> content_type_xhtml, (Hashtbl.find ent_bodies x)
    | x                           -> content_type_xhtml, return (not_found x)

end
 
module Wiki = struct
  open Wiki

  let sidebar = Wiki.short_html_of_categories entries categories

  let read_file f = read_file ("/wiki/" ^ f)

  (* Make a full Html.t including RSS link and headers from an wiki page *)
  let make ?title ?disqus ?top_para ?right_column left_column =
    let url = sprintf "/wiki/atom.xml" in
    let extra_header = <:xml< 
     <link rel="alternate" type="application/atom+xml" href=$str:url$ />
    >> in
    let title = "wiki" ^ match title with 
      | Some x -> " :: " ^ x 
      | None -> "" 
    in
    let body = Wiki.html_of_page ?disqus ?top_para ?right_column ~left_column ~sidebar in  
    Template.t ~extra_header "Wiki" title body >|= Html.to_string

  (* Main wiki page Html.t fragment with the index page *)
  let main_page =
    let top = Wiki.html_of_file read_file "index-t.md" in
    let idx = Wiki.html_of_index read_file in
    let upd = Wiki.html_of_recent_updates Wiki.entries in
    make ~title:"index" ~top_para:top ~right_column:upd idx

  let ent_bodies = Hashtbl.create 1
  let _ =
    List.iter (fun entry ->
      let title = entry.subject in
      let top  = Wiki.html_of_entry read_file entry in
      let empty = return <:xml< >> in
      let body = make ~title ~disqus:entry.permalink ~top_para:top empty in
      Hashtbl.add ent_bodies entry.permalink body
    ) Wiki.entries

  let lt1_bodies = Hashtbl.create 1
  let _ =
    List.iter (fun (lt1,_) ->
       let title = lt1 in
       let left  = Wiki.html_of_category Wiki.entries (lt1, None) in
       Hashtbl.add lt1_bodies lt1 (make ~title (return left));
    ) Wiki.categories

  let lt2_bodies = Hashtbl.create 1
  let _ =
    List.iter (fun (lt1,lt2s) ->
      List.iter (fun lt2 ->
         let title = lt1 ^ " :: " ^ lt2 in
         let left = Wiki.html_of_category Wiki.entries (lt1, Some lt2) in
         Hashtbl.add lt2_bodies lt2 (make ~title (return left));
      ) lt2s
    ) Wiki.categories

  let atom_feed = 
    lwt f = Wiki.atom_feed read_file Wiki.entries in
    return (Xml.to_string (Atom.xml_of_feed ~self:("/wiki/atom.xml") f))

  let not_found x =
    let left =
      sprintf "Not found: %s (known links: wiki/%s)"
        (String.concat " ... " x) 
        (String.concat " " 
           (Hashtbl.fold (fun k v a -> k :: a) 
              ent_bodies [])) in
    make ~title:"Not Found" (return <:xml<$str:left$>>)

  let t = function
    | []                          -> content_type_xhtml, main_page
    | ["atom.xml"]                -> ["content-type","application/atom+xml; charset=UTF-8"], atom_feed
    | [x] when permalink_exists x -> content_type_xhtml, (Hashtbl.find ent_bodies x)
    | x                           -> content_type_xhtml, not_found x

  let tag = function
    | []        -> main_page
    | [lt1]     -> (try Hashtbl.find lt1_bodies lt1 with Not_found -> not_found [lt1])
    | [lt1;lt2] -> (try Hashtbl.find lt2_bodies lt2 with Not_found -> not_found [lt2])
    | x         -> not_found x
end

