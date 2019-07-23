//# sourceURL=J_IntesisWMPGateway1_ALTUI.js
/* globals window,MultiBox */

"use strict";

var IntesisWMPGateway_ALTUI = ( function( window, undefined ) {

		function _draw( device ) {
				var html ="";
				var s;
				s += MultiBox.getStatus( device, "urn:toggledbits-com:serviceId:IntesisWMPGateway1", "DisplayStatus");
				html += '<div>' + s + '</div>';
				return html;
		}
	return {
		DeviceDraw: _draw,
	};
})( window );
