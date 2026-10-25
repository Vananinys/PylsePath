import unittest
from unittest.mock import AsyncMock, patch
import httpx
from fastapi import HTTPException
from fastapi.testclient import TestClient
from pydantic import ValidationError
import api_models
import main
import route_service

VALID = dict(start_lat=52.5, start_lon=85.2, end_lat=53, end_lon=86, profile='bike')

class RouteApiSecurityTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(main.app)

    def test_invalid_coordinates_never_reach_upstream(self):
        with patch('main.get_route_details', new_callable=AsyncMock) as upstream:
            for field, bad in [('start_lat',91),('end_lat',-91),('start_lon',181),
                               ('end_lon',-181),('start_lat','NaN'),('end_lon','Infinity')]:
                with self.subTest(field=field, bad=bad):
                    response=self.client.post('/api/v1/route',json={**VALID,field:bad})
                    self.assertEqual(response.status_code,422)
                    self.assertEqual(response.json(),{'detail':'Invalid route request'})
            upstream.assert_not_awaited()

    def test_both_request_models_reject_nonfinite_and_out_of_range(self):
        for model in [main.RouteRequest,api_models.RouteRequest]:
            for value in [float('nan'),float('inf'),float('-inf'),91,-91]:
                with self.assertRaises(ValidationError): model(**{**VALID,'start_lat':value})

    def test_valid_request_still_works(self):
        with patch('main.get_route_details',new_callable=AsyncMock,return_value={'points':[]}) as upstream:
            response=self.client.post('/api/v1/route',json=VALID)
            self.assertEqual(response.status_code,200)
            upstream.assert_awaited_once()

    def test_internal_exception_is_not_exposed(self):
        with patch('main.get_route_details',new_callable=AsyncMock,side_effect=RuntimeError('private-token@internal-host')):
            response=self.client.post('/api/v1/route',json=VALID)
            self.assertEqual(response.status_code,500)
            self.assertNotIn('private-token',response.text)

    def test_untrusted_browser_origin_is_not_allowed(self):
        response=self.client.options('/api/v1/route',headers={
            'Origin':'https://attacker.example','Access-Control-Request-Method':'POST'})
        self.assertNotIn('access-control-allow-origin',response.headers)

class RoutingUpstreamSecurityTests(unittest.IsolatedAsyncioTestCase):
    async def test_network_and_status_errors_do_not_leak_url(self):
        request=httpx.Request('GET','https://internal.example/private-key')
        errors=[httpx.ConnectError('private-key',request=request),
                httpx.HTTPStatusError('private-key',request=request,response=httpx.Response(500,request=request))]
        for error in errors:
            client=AsyncMock()
            client.__aenter__.return_value=client
            client.get.side_effect=error
            with patch('route_service.httpx.AsyncClient',return_value=client):
                with self.assertRaises(HTTPException) as raised:
                    await route_service.get_route_details(1,2,3,4)
                self.assertEqual(raised.exception.status_code,502)
                self.assertNotIn('private-key',raised.exception.detail)

    async def test_invalid_response_is_sanitized(self):
        client=AsyncMock()
        client.__aenter__.return_value=client
        client.get.return_value=httpx.Response(200,json={'code':'Ok','routes':[]},request=httpx.Request('GET','https://example.com'))
        with patch('route_service.httpx.AsyncClient',return_value=client):
            with self.assertRaises(HTTPException) as raised:
                await route_service.get_route_details(1,2,3,4)
            self.assertEqual(raised.exception.status_code,502)
            self.assertEqual(raised.exception.detail,'Invalid routing response')

if __name__=='__main__': unittest.main()
