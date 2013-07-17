open Cow
open Printf
open Lwt

type body = 
  | File of string
  | Html of Html.t

type t = {
  permalink: string;
  title: string;
  slides: body;
}


let render slide =
  <:xml<

<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
      <title>$str:slide.title$</title>
      <link rel="stylesheet" href="../css/reveal.min.css">
      </head>
      
      <body>
        <div class="reveal">
          <div class="slides">
            $str:slide.slides$
          </div>
        </div>
        
        <script src="../lib/js/head.min.js"></script>
        <script src="../js/reveal.min.js"></script>
        <script>
          Reveal.initialize();
        </script>
      </body>
    </html>
  >>
  
