from unittest import TestCase, mock
import os

from kestra import Kestra

class TestKestra(TestCase):
    def setUp(self):
        self.kestra = Kestra

        self.namespace = 'staging.process'
        self.flow = 'load-stg_rzbk_liste_00287x'
        self.parameter={ "reportingDate": "20230331" }

    @mock.patch.dict(os.environ, {'KESTRA_HOST': 'http://localhost:8086', 'KESTRA_USER': 'test','KESTRA_PASSWORD': 'test'})
    def test_execute_flow_no_auth(self):
         result = self.kestra.execute_flow(self.namespace, self.flow, self.parameter)

         print(result.status)
         print(result.log)
         print(result.error)
         return 
        


if __name__ == '__main__':
    unittest.main()