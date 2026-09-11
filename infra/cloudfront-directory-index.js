function handler(event) {
  var request = event.request;
  var uri = request.uri;

  // Leave real files alone (favicon.svg, og-image.jpg, audio/*.mp3, …).
  if (uri.indexOf(".") !== -1) {
    return request;
  }

  // /lineup → /lineup/index.html · /lineup/ → /lineup/index.html · / → /index.html
  if (uri.endsWith("/")) {
    request.uri = uri + "index.html";
  } else {
    request.uri = uri + "/index.html";
  }
  return request;
}
