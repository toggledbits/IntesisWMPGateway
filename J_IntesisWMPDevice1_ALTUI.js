//# sourceURL=J_IntesisWMPDevice1_ALTUI.js
"use strict";

var IntesisWMPDevice1_ALTUI = ( function( window, undefined ) {

        function _draw( device ) {
                var html ="";
                var w = MultiBox.getWeatherSettings();
                var s;
                s = MultiBox.getStatus( device, "urn:toggledbits-com:serviceId:IntesisWMPDevice1", "DisplayTemperature");
                s += "<br/>" + MultiBox.getStatus( device, "urn:toggledbits-com:serviceId:IntesisWMPDevice1", "DisplayStatus");
                html += '<div>' + s + '</div>';
                return html;
        }
    return {
        DeviceDraw: _draw,
    };
})( window );
