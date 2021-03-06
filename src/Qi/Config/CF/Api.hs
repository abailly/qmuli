{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}

module Qi.Config.CF.Api (toResources) where

import           Data.Aeson                     (Value (Bool), object)
import qualified Data.ByteString.Lazy           as LBS
import qualified Data.HashMap.Strict            as SHM
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Qi.Config.AWS
import           Qi.Config.AWS.Api
import           Qi.Config.AWS.Api.Accessors
import           Qi.Config.AWS.Lambda.Accessors
import           Qi.Config.Identifier
import           Stratosphere                   hiding (Delete, name)
import           Text.Heredoc


toResources config = Resources $ foldMap toStagedApiResources $ getAllApis config

  where
    jsonContentType = "application/json"

    toStagedApiResources :: (ApiId, Api) -> [Resource]
    toStagedApiResources (aid, api) = deploymentResource:apiResources
      where
        apiResources = [ apiResource ] ++ foldMap toApiChildResources (getApiChildren (Left aid) config)

        apiResName = getApiCFResourceName api

        apiResource = (
          resource apiResName $
            ApiGatewayRestApiProperties $
            apiGatewayRestApi $
              Literal (api ^. aName)
          )

        deploymentResource :: Resource
        deploymentResource = (
            resource name $
              ApiGatewayDeploymentProperties $
              apiGatewayDeployment
                (Ref apiResName)
                & agdStageName ?~ "v1"
          )
          & dependsOn ?~ deps

          where
            name = getApiStageCFResourceName api
            deps = map (^. resName) apiResources


        toApiChildResources :: ApiResourceId -> [Resource]
        toApiChildResources arid =
          [ apirResource ] ++
          methodResources ++
          foldMap toApiChildResources (getApiChildren (Right arid) config)

          where
            apir = getApiResourceById arid config
            apirResName = getApiResourceCFResourceName apir

            apirResource =
              case apir of
                ApiResource{_arParent = Left aid} ->
                  let
                    apiParent = GetAtt apiResName "RootResourceId"
                  in
                    resource apirResName $
                      ApiGatewayResourceProperties $
                      apiGatewayResource
                        apiParent
                        (Literal $ apir ^. arName)
                        (Ref apiResName)


                ApiResource{_arParent = Right arid'} ->
                  let
                    apirParentResName = getApiResourceCFResourceName $ getApiResourceById arid' config
                  in
                    resource apirResName $
                      ApiGatewayResourceProperties $
                      apiGatewayResource
                        (Ref apirParentResName)
                        (Literal $ apir ^. arName)
                        (Ref apiResName)




            methodResources = [ corsMethodResource ] ++ map toMethodResource (apir ^. arMethodConfigs)

            corsMethodResource =
                resource name $
                  ApiGatewayMethodProperties $
                  apiGatewayMethod
                    NONE
                    OPTIONS
                    (Ref apirResName)
                    (Ref apiResName)
                    & agmeIntegration ?~ integration
                    & agmeMethodResponses ?~ [ methodResponse ]

              where
                name = getApiMethodCFResourceName apir Options

                methodResponse = apiGatewayMethodResponse "200"
                  & agmrResponseModels ?~ responseModels
                  & agmrResponseParameters ?~ responseParams

                  where
                    responseModels = [(jsonContentType, "Empty")]

                    responseParams = [
                        ("method.response.header.Access-Control-Allow-Headers", Bool False)
                      , ("method.response.header.Access-Control-Allow-Methods", Bool False)
                      , ("method.response.header.Access-Control-Allow-Origin", Bool False)
                      ]

                integration =
                  apiGatewayIntegration MOCK
                  & agiIntegrationHttpMethod ?~ POST -- looks like this should always be "POST"
                  & agiPassthroughBehavior ?~ WHEN_NO_MATCH
                  & agiRequestTemplates ?~ requestTemplates
                  & agiIntegrationResponses ?~ [ integrationResponse ]

                  where
                    requestTemplates = [ (jsonContentType, "{\"statusCode\": 200}") ]

                    integrationResponse = apiGatewayIntegrationResponse
                      & agirResponseTemplates ?~ responseTemplates
                      & agirResponseParameters ?~ responseParams
                      & agirStatusCode ?~ "200"

                      where
                        responseTemplates = [ (jsonContentType, "") ]
                        responseParams = [
                            ("method.response.header.Access-Control-Allow-Headers", "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'")
                          , ("method.response.header.Access-Control-Allow-Methods", "'DELETE,GET,HEAD,POST,PUT,OPTIONS,TRACE'")
                          , ("method.response.header.Access-Control-Allow-Origin", "'*'")
                          ]


            toMethodResource ApiMethodConfig{_verb, _lbdId} = (
                resource name $
                  ApiGatewayMethodProperties $
                  apiGatewayMethod
                    NONE
                    (verb _verb)
                    (Ref apirResName)
                    (Ref apiResName)
                    & agmeIntegration ?~ integration
                    & agmeMethodResponses ?~ methodResponses
              )
              & dependsOn ?~ [
                    lbdPermResName
                  ]

              where
                name = getApiMethodCFResourceName apir _verb

                verb Get     = GET
                verb Post    = POST
                verb Put     = PUT
                verb Delete  = DELETE
                verb Head    = HEAD
                verb Options = OPTIONS

                -- these are all possible response types (statuses) for this method
                methodResponses = map methodResponse ["200", "400", "404", "500"]
                  where
                    methodResponse status = apiGatewayMethodResponse status
                      & agmrResponseParameters ?~ responseParams

                    responseParams = [
                        ("method.response.header.Access-Control-Allow-Headers", Bool False)
                      , ("method.response.header.Access-Control-Allow-Methods", Bool False)
                      , ("method.response.header.Access-Control-Allow-Origin", Bool False)
                      ]

                lbdResName = getLambdaCFResourceNameFromId _lbdId config
                lbdPermResName = getLambdaPermissionCFResourceName $ getLambdaById _lbdId config

                integration =
                  apiGatewayIntegration AWS
                  & agiIntegrationHttpMethod ?~ POST -- looks like this should always be "POST" no matter what the http verb was used on the endpoint
                  & agiUri ?~ uri
                  & agiPassthroughBehavior ?~ passthroughBehavior
                  & agiRequestTemplates ?~ requestTemplates
                  & agiIntegrationResponses ?~ integrationResponses

                  where
                    uri = (Join "" [
                        "arn:aws:apigateway:"
                      , Ref "AWS::Region"
                      , ":lambda:path/2015-03-31/functions/"
                      , GetAtt lbdResName "Arn"
                      , "/invocations"])

                    requestTemplates =
                      -- TODO: all the same for now. Need to figure out how it should differ for different verbs
                      [ (jsonContentType, postTemplate) ]
                      {- case _verb of -}
                        {- Get  -> [ (jsonContentType, postTemplate) ] -}
                        {- Post -> [ (jsonContentType, postTemplate) ] -}

                      where
                        {- getTemplate   = [there|./js/get_template.js|] -}
                        postTemplate  = [there|./js/post_template.js|]

                    passthroughBehavior =
                      -- TODO: all the same for now. Need to figure out how it should differ for different verbs
                      WHEN_NO_TEMPLATES
                      {- case _verb of -}
                        {- Get  -> WHEN_NO_TEMPLATES -}
                        {- Post -> WHEN_NO_TEMPLATES -}


                    integrationResponses = [ successIntegrationResponse ] ++
                      map errorIntegrationResponse [
                          "400"
                        , "404"
                        , "500"
                        ]

                    successIntegrationResponse = apiGatewayIntegrationResponse
                      & agirResponseTemplates ?~ responseTemplates
                      & agirStatusCode ?~ "200"
                      & agirResponseParameters ?~ responseParams

                      where
                        responseTemplates = [ (jsonContentType, [there|./js/success_response_template.js|]) ]

                    errorIntegrationResponse errorStatus = apiGatewayIntegrationResponse
                      & agirResponseTemplates ?~ responseTemplates
                      & agirStatusCode ?~ (Literal $ T.pack errorStatus)
                      & agirSelectionPattern ?~ (Literal . T.pack $ "^\\[" ++ errorStatus ++ "\\].*")
                      & agirResponseParameters ?~ responseParams

                      where
                        responseTemplates = [ (jsonContentType, [there|./js/error_response_template.js|]) ]

                    responseParams = [
                        ("method.response.header.Access-Control-Allow-Headers", "'Content-Type,X-Amz-Date,Authorization,X-Api-Key'")
                      , ("method.response.header.Access-Control-Allow-Methods", "'DELETE,GET,HEAD,POST,PUT,OPTIONS,TRACE'")
                      , ("method.response.header.Access-Control-Allow-Origin", "'*'")
                      ]



